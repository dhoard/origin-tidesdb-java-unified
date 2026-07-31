# tidesdb-java-unified

A self-contained Java binding for [TidesDB](https://github.com/tidesdb/tidesdb). The generated JAR embeds the TidesDB core engine (`libtidesdb.so`) together with its JNI bridge (`libtidesdb_jni.so`) and statically-linked compression dependencies (zstd, LZ4, Snappy), so applications do not need a separate TidesDB installation or a custom `java.library.path`.

> **Current platform:** Linux x86-64 with glibc. The preflight check in `build-dependencies.sh` enforces this; other operating systems and architectures are not yet supported.

## Dependency configuration

All dependency sources are configured in [`dependencies.properties`](dependencies.properties) using a branch + tag model:

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

To pin a specific release, set the `.tag` value for the relevant component. CI and local builds always clone the pinned commit, so a build is reproducible as long as the pins are unchanged.

| Component | Branch | Pinned Tag |
|---|---|---|
| TidesDB | master | v9.3.13 |
| tidesdb-java | master | v0.8.3 |
| zstd | dev | v1.5.7 |
| LZ4 | dev | v1.10.0 |
| Snappy | main | 1.2.2 |

## Build

The build has a single entry point:

```bash
./build.sh
```

`./build.sh` runs `./build-dependencies.sh` (builds the pinned native dependencies) and then `./mvnw clean install` (builds and installs the unified JAR).

The whole build requires network access to GitHub (to clone the pinned upstream sources) and Maven Central (for the Java toolchain). On success, the unified JAR is installed into the local Maven repository.

### What `./build-dependencies.sh` does

`./build.sh` calls this script first. It performs the following steps:

1. **Preflight** — validates the host (Linux x86-64) and the required toolchain, and checks for at least 2 GB of free disk space.
2. **Clean** — removes any previous `./build` output and any leftover `./workspace` from an interrupted run.
3. **Clone** — clones the pinned upstream sources (TidesDB, tidesdb-java, zstd, LZ4, Snappy) into `./workspace` and checks out the pinned tags.
4. **Compression** — builds zstd, LZ4, and Snappy as static, position-independent archives.
5. **TidesDB core** — builds `libtidesdb.so` as a shared library with the compression libraries statically linked in (S3 and sanitizers disabled).
6. **JNI bridge** — builds `libtidesdb_jni.so` from the *unmodified* upstream `tidesdb-java` JNI sources, linked against the freshly built `libtidesdb.so`.
7. **Verify** — audits both libraries with `ldd` and `readelf`: no forbidden dynamic dependencies (zstd, LZ4, Snappy, curl, OpenSSL, or the optional S3 implementation) and no suspicious RPATH/RUNPATH entries.
8. **Upstream Java artifact** — builds the pinned `tidesdb-java` sources with their own Maven wrapper (`-DskipTests`) and installs the artifact into the local Maven repository; the clone is checked to remain unmodified.
9. **Copy** — copies the two `.so` files into `build/generated-resources/native/linux-x86_64/`, where the Maven build picks them up.

All clone/build work happens under `./workspace`, which is emptied on both success and failure. `./build` is created and cleaned before `./workspace` so stale generated resources never survive a run.

### What `./mvnw clean install` does

The Maven phase compiles `NativeLibrary`, compiles the `module-info` descriptor, runs the unit and integration tests, and shades the upstream `tidesdb-java` API classes into a single JAR along with the embedded native libraries, the project `LICENSE`, and `NOTICE`. This project's own `NativeLibrary` implementation replaces the upstream one in the shaded JAR.

This produces the unified JAR and related artifacts under `target/`:

```text
target/
├── tidesdb-java-unified-0.1.0.jar
├── tidesdb-java-unified-0.1.0-sources.jar
├── tidesdb-java-unified-0.1.0-javadoc.jar
└── original-tidesdb-java-unified-0.1.0.jar
```

### Requirements

Run on Linux x86-64 with at least 2 GB of free disk space. The preflight check requires:

- Bash
- Git
- CMake 3.25 or later (required by TidesDB)
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

### Output libraries

The native dependency phase (`build-dependencies.sh`, invoked by `./build.sh`) leaves the native libraries at:

```text
build/generated-resources/native/linux-x86_64/
├── libtidesdb.so
└── libtidesdb_jni.so
```

These are packaged into the JAR under `/native/linux-x86_64/`.

### Verification

After the full build, run the checked-in example:

```bash
./mvnw -q -f examples/basic/pom.xml verify
```

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

This project's own test suite handles this automatically: a `jdk22+` Maven profile sets `--enable-native-access=ALL-UNNAMED` in Surefire, and the example runs with the flag via the Exec plugin.

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
src/main/java/com/tidesdb/NativeLibrary.java   unified embedded-native loader
src/main/module/module-info.java               JPMS descriptor (module com.tidesdb)
src/test/java/com/tidesdb/                     loader unit + packaged-JAR integration tests
examples/basic/                                standalone packaged-JAR acceptance test
build-dependencies.sh                          native dependency build
build.sh                                       full build entry point
```

The Java API comes from the upstream `tidesdb-java` artifact built from a pinned clone. `NativeLibrary.java` is maintained by this project to provide deterministic embedded-native extraction. The cloned upstream Java and JNI source is never patched, copied into the source tree, or formatted by this build. The `cmake/` directory contains a reference native build definition only; the scripts build from the upstream sources' own CMake files.

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

GitHub Actions (`.github/workflows/build.yaml` and `manual-build.yaml`) runs `bash ./build.sh` on `ubuntu-22.04` for pushes and pull requests targeting `master` (`manual-build.yaml` is a manual `workflow_dispatch` trigger). CI uses SHA-pinned official actions and Corretto JDK 11. It installs the build tools with `apt-get` and then runs the full build; no artifacts are uploaded.

By default CI pulls the latest commit on each configured branch. To pin CI to specific versions, set the `.tag` values in `dependencies.properties`.

## Licensing

This project is licensed under the Apache License 2.0 (see [`LICENSE`](LICENSE)). It embeds and redistributes upstream components, each under its own license:

| Component | License |
|---|---|
| TidesDB | Mozilla Public License 2.0 (MPL-2.0) |
| tidesdb-java | Mozilla Public License 2.0 (MPL-2.0) |
| zstd | BSD 3-Clause |
| LZ4 | BSD 2-Clause |
| Snappy | Apache License 2.0 |

The `NOTICE` file lists these components and licenses, and both `LICENSE` and `NOTICE` are bundled into the generated JAR under `META-INF/`.
