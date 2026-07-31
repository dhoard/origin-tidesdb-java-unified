# tidesdb-java-unified

A self-contained Java binding for [TidesDB](https://github.com/tidesdb/tidesdb). The generated JAR embeds the TidesDB core engine (`libtidesdb.so`) together with its JNI bridge (`libtidesdb_jni.so`) and statically-linked compression dependencies, so applications do not need a separate TidesDB installation or a custom `java.library.path`.

> **Current platform:** Linux x86-64 with glibc. Other operating systems and architectures are not yet supported.

## Upstream configuration

All upstream sources are configured in [`upstream.properties`](upstream.properties) using a branch + tag model:

```properties
tidesdb.repo=https://github.com/tidesdb/tidesdb.git
tidesdb.branch=master
tidesdb.tag=v9.3.13

tidesdb-java.repo=https://github.com/tidesdb/tidesdb-java.git
tidesdb-java.branch=master
tidesdb-java.tag=v0.8.3
```

| Field | Purpose |
|---|---|
| `.repo` | Repository URL |
| `.branch` | Branch to clone |
| `.tag` | Tag to checkout (empty = latest on branch) |

To pin a specific release, set the `.tag` value for the relevant component.

| Component | Branch | Pinned Tag |
|---|---|---|
| TidesDB | master | v9.3.13 |
| tidesdb-java | master | v0.8.3 |
| zstd | dev | v1.5.7 |
| LZ4 | dev | v1.10.0 |
| Snappy | main | 1.2.2 |

## Build

The complete build has one entry point:

```bash
./build.sh
```

Run it on Linux x86-64 with at least 2 GB of free disk space. It requires:

- Bash
- Git
- CMake 3.25 or later
- Ninja
- GCC and G++
- GNU binutils (`ld`, `ar`, `ranlib`, and `readelf`)
- Java Development Kit 11 or later (`java`, `javac`, and `jar`)
- `curl`, `file`, `ldd`, `sha256sum`, and `tar`

For Ubuntu 22.04, the non-JDK build dependencies can be installed with:

```bash
sudo apt-get update
sudo apt-get install -y cmake ninja-build gcc g++ binutils curl file tar
```

Install a JDK 11 or later separately and ensure `java`, `javac`, and `jar` resolve from `PATH`.

The build performs the following steps:

1. validates the host and toolchain;
2. clones all upstream projects at configured branch/tag;
3. builds static zstd, LZ4, and Snappy compression libraries;
4. builds TidesDB as a shared library (`libtidesdb.so`) with statically-linked compression;
5. compiles the unchanged upstream JNI source and links it into `libtidesdb_jni.so` against the built TidesDB;
6. audits the native libraries for forbidden dynamic dependencies;
7. builds the pinned `tidesdb-java` Java artifact without modifying its source;
8. copies native libraries into the generated resources and builds the unified Java artifact;
9. runs the standalone example against the packaged JAR using an isolated Maven repository.

The script uses a temporary directory under `/tmp` for all build work and requires network access to GitHub and Maven Central.

## Build outputs

A successful build creates the unified JAR and related artifacts under `target/`:

```text
target/
├── tidesdb-java-unified-0.1.0.jar
├── tidesdb-java-unified-0.1.0-sources.jar
├── tidesdb-java-unified-0.1.0-javadoc.jar
└── original-tidesdb-java-unified-0.1.0.jar
```

Native libraries are also copied to `libs/` for local inspection:

```text
libs/
├── libtidesdb.so
└── libtidesdb_jni.so
```

The JAR is installed into the local Maven repository by `./mvnw clean install`.

## Use from Maven

`./build.sh` installs the artifact into the local Maven repository. It is not currently published to Maven Central.

```xml
<dependency>
  <groupId>com.tidesdb</groupId>
  <artifactId>tidesdb-java-unified</artifactId>
  <version>0.1.0</version>
</dependency>
```

The application does not need to set `LD_LIBRARY_PATH` or `java.library.path`. On first use, `NativeLibrary` extracts the embedded libraries into a versioned, SHA-256-addressed directory beneath `java.io.tmpdir` and loads them in dependency order (`libtidesdb.so` first, then `libtidesdb_jni.so`) with `System.load(...)`.

For development only, an explicit JNI library path can be selected with an absolute path:

```bash
java -Dtidesdb.native.library.path=/absolute/path/libtidesdb_jni.so -jar ...
```

When using the override, you must ensure `libtidesdb.so` is discoverable by the dynamic linker.

## Native access and JDK 16+

`NativeLibrary` uses `System.load()` to load the embedded JNI shared library. Starting with JDK 16, `java.lang.System::load` is a **restricted method** — the JVM emits a warning when it is called:

```
WARNING: A restricted method in java.lang.System has been called
WARNING: java.lang.System::load has been called by com.tidesdb.NativeLibrary
         in an unnamed module (file:...)
WARNING: Use --enable-native-access=ALL-UNNAMED to avoid a warning
         for callers in this module
WARNING: Restricted methods will be blocked in a future release
         unless native access is enabled
```

To suppress the warning and ensure forward compatibility, pass the JVM flag. Use `ALL-UNNAMED` when the JAR is on the **class path** (the usual case):

```bash
java --enable-native-access=ALL-UNNAMED -jar myapp.jar
```

Use `com.tidesdb` when the JAR is on the **module path**:

```bash
java --enable-native-access=com.tidesdb --module-path=... -jar myapp.jar
```

Or with Maven Surefire (for tests):

```xml
<plugin>
  <groupId>org.apache.maven.plugins</groupId>
  <artifactId>maven-surefire-plugin</artifactId>
  <configuration>
    <argLine>--enable-native-access=ALL-UNNAMED</argLine>
  </configuration>
</plugin>
```

Or with the Maven Exec plugin:

```xml
<plugin>
  <groupId>org.codehaus.mojo</groupId>
  <artifactId>exec-maven-plugin</artifactId>
  <configuration>
    <jvmArgs>
      <jvmArg>--enable-native-access=ALL-UNNAMED</jvmArg>
    </jvmArgs>
  </configuration>
</plugin>
```

### When to use `ALL-UNNAMED` vs `com.tidesdb`

The `tidesdb-java-unified` JAR ships with a `module-info.class` (module name `com.tidesdb`). Which flag you need depends on how the JAR is loaded:

| JAR location | Flag | Reason |
|---|---|---|
| **Class path** (typical Maven dependency, `java -cp`, `java -jar`) | `ALL-UNNAMED` | JAR on the class path is part of the unnamed module |
| **Module path** (`--module-path`, `--add-modules`) | `com.tidesdb` | JAR on the module path is a named module |

For most users, the JAR sits on the class path, so `ALL-UNNAMED` is the right choice. If you place the JAR on the module path, the more specific `com.tidesdb` flag applies.

> **Future direction:** If the JDK blocks unrestricted `System.load()` entirely, the planned migration is to the [Foreign Function & Memory API](https://openjdk.org/jeps/454) (JEP 454), which replaces JNI and provides its own access-control mechanism.

## Example

The checked-in example under [`examples/basic`](examples/basic) opens a database, writes and reads a value, closes the database, and verifies persistence after reopening it.

After building the main project, run:

```bash
./mvnw -q -f examples/basic/pom.xml verify
```

A successful run exits with code 0 (no output by default).

## Development

Production sources and tests are checked in:

```text
src/main/java/com/tidesdb/NativeLibrary.java     unified embedded-native loader
examples/basic/                                   standalone packaged-JAR acceptance test
cmake/CMakeLists.txt                              native build definition
```

The Java API comes from the upstream `tidesdb-java` artifact built from a pinned clone. `NativeLibrary.java` is maintained by this project to provide deterministic embedded-native extraction. The cloned upstream Java and JNI source is never patched, copied into the source tree, or formatted by this build.

To apply Java formatting:

```bash
./mvnw spotless:apply
```

The canonical end-to-end verification remains:

```bash
./build.sh
```

## Native dependency policy

The packaged libraries must not dynamically depend on separately installed copies of:

- zstd
- LZ4
- Snappy
- curl, OpenSSL, or the optional S3 implementation

The JNI bridge (`libtidesdb_jni.so`) dynamically depends on the *bundled* `libtidesdb.so` (the TidesDB core engine), which is extracted to the same cache directory at runtime. Compression libraries are statically linked into `libtidesdb.so` and do not appear as dynamic dependencies.

Normal Linux system dependencies such as glibc are permitted. The build enforces this policy with `ldd` and `readelf`.

## CI

GitHub Actions (`.github/workflows/build.yaml` and `manual-build.yaml`) runs `./build.sh` for pushes and pull requests targeting `main`, then retains `dist/` as a workflow artifact. CI uses SHA-pinned official actions and Corretto JDK 11.

By default CI pulls the latest commit on each configured branch. To pin CI to specific versions, set the `.tag` values in `upstream.properties`.

## Licensing

TidesDB and tidesdb-java are distributed under the Mozilla Public License 2.0. This project preserves their notices and includes license information for bundled native dependencies in [`LICENSES`](LICENSES) and each generated `dist/` directory.
