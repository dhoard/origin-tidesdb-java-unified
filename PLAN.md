# tidesdb-java-unified project plan

> **Current source-integration decision:** [`BUILD-PLAN.md`](BUILD-PLAN.md) supersedes the earlier vendoring and patching alternatives in this document. Cloned upstream source is built unchanged.

## 1. Goal

Build one platform-specific Java dependency containing the TidesDB Java API and the native JNI library for the build platform. Every supported OS/architecture builds and tests its own final JAR; native outputs from different platforms are never combined into a universal JAR. At runtime the Java code validates the current platform, extracts that JAR's native artifact, and loads it with `System.load(...)`.

The MVP build and artifact target Linux x86-64 only. Publishing is explicitly out of scope for the MVP.

Target usage:

```xml
<dependency>
  <groupId>com.tidesdb</groupId>
  <artifactId>tidesdb-java-unified</artifactId>
  <version>...</version>
</dependency>
```

```java
try (TidesDB db = TidesDB.open("/path/to/db", config)) {
    // No native installation and no -Djava.library.path required.
}
```

“Static” in this plan means that TidesDB and its non-system dependencies are linked into the JNI shared library. A JNI library must remain a `.so`, `.dylib`, or `.dll` so that the JVM can load it. The final artifact must not require a separately installed `libtidesdb`, zstd, lz4, or snappy library.

## 2. Validation example

Include a standalone Maven example under `examples/basic/` and run it against the packaged unified JAR in CI. It must not set `java.library.path`, `PATH`, `LD_LIBRARY_PATH`, or `DYLD_LIBRARY_PATH` and must run on a machine without TidesDB installed.

`examples/basic/pom.xml` should contain only the unified runtime dependency (plus normal Maven build plugins):

```xml
<dependency>
  <groupId>com.tidesdb</groupId>
  <artifactId>tidesdb-java-unified</artifactId>
  <version>${tidesdb.version}</version>
</dependency>
```

`examples/basic/src/main/java/example/UnifiedExample.java`:

```java
package example;

import com.tidesdb.ColumnFamily;
import com.tidesdb.ColumnFamilyConfig;
import com.tidesdb.Config;
import com.tidesdb.LogLevel;
import com.tidesdb.NativeLibrary;
import com.tidesdb.TidesDB;
import com.tidesdb.Transaction;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

public final class UnifiedExample {
    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("tidesdb-unified-example-");
        byte[] key = "hello".getBytes(StandardCharsets.UTF_8);
        byte[] expected = "tidesdb-java-unified".getBytes(StandardCharsets.UTF_8);

        // This call must extract and load the library embedded in the unified JAR.
        NativeLibrary.load();
        if (!NativeLibrary.isLoaded()) {
            throw new IllegalStateException("Embedded TidesDB JNI library was not loaded");
        }

        Config config = Config.builder(directory.resolve("db").toString())
                .numFlushThreads(1)
                .numCompactionThreads(1)
                .logLevel(LogLevel.INFO)
                .blockCacheSize(16 * 1024 * 1024)
                .maxOpenSSTables(64)
                .build();

        try (TidesDB db = TidesDB.open(config)) {
            db.createColumnFamily("example", ColumnFamilyConfig.defaultConfig());
            ColumnFamily columnFamily = db.getColumnFamily("example");

            try (Transaction transaction = db.beginTransaction()) {
                transaction.put(columnFamily, key, expected);
                transaction.commit();
            }

            try (Transaction transaction = db.beginTransaction()) {
                byte[] actual = transaction.get(columnFamily, key);
                if (!Arrays.equals(expected, actual)) {
                    throw new AssertionError("Unexpected value returned from TidesDB");
                }
            }
        }

        // Reopen the database to prove persistence as well as JNI invocation.
        try (TidesDB db = TidesDB.open(config)) {
            ColumnFamily columnFamily = db.getColumnFamily("example");
            try (Transaction transaction = db.beginTransaction()) {
                if (!Arrays.equals(expected, transaction.get(columnFamily, key))) {
                    throw new AssertionError("Value was not preserved after reopen");
                }
            }
        }

        System.out.println("tidesdb-java-unified validation succeeded");
    }
}
```

Document and execute the example with:

```bash
./mvnw -q -f examples/basic/pom.xml verify
```

All Maven operations, including the example build, must use the checked-in Maven Wrapper (`./mvnw`), never a system `mvn` executable. The example Maven build should run `UnifiedExample` during `verify`, not merely compile it. In release CI, resolve the candidate artifact from an isolated temporary Maven repository and inspect the dependency tree to assert that `tidesdb-java-unified` is the only runtime dependency. Success requires exit code zero and the message:

```text
tidesdb-java-unified validation succeeded
```

Run this same example in each supported OS/architecture job against the platform-specific JAR produced by that same job. For the MVP, run it on Linux x86-64 only. This is the primary end-user acceptance test; the larger upstream test suite remains the detailed regression test.

## 3. Initial upstream assessment

Current upstream versions observed while preparing this plan:

- `tidesdb/tidesdb`: `v9.3.13`
- `tidesdb/tidesdb-java`: `v0.8.3`
- Minimum Java version: 11

Relevant existing behavior:

- TidesDB already supports `BUILD_SHARED_LIBS=OFF` and enables position-independent code.
- `tidesdb-java` builds `tidesdb_jni` separately and normally locates an installed TidesDB library.
- `NativeLibrary` already has a resource extraction fallback, but its resource path is based directly on raw `os.name` and `os.arch` values and is not yet suitable as a stable cross-platform packaging contract.
- Existing upstream CI tests dynamically installed native libraries. It does not prove that the JNI library is self-contained.

The TidesDB and Java binding versions must be treated as a tested pair. The current major-version difference means compatibility must be verified rather than inferred from version numbers.

## 4. Supported platform matrix

The MVP has one supported build and runtime target. Later targets follow the same independent build/test/package model:

| Resource classifier | Runner/toolchain | Native file | Status |
|---|---|---|---|
| `linux-x86_64` | Ubuntu, GCC | `libtidesdb_jni.so` | **MVP** |

Future candidates, not part of the MVP, are Linux ARM64, macOS Intel/ARM64, and Windows x64. Each candidate will produce a separate platform-specific JAR after it has native CI execution coverage.

Decide before implementation whether the MVP targets glibc only and what minimum glibc version is supported. Do not claim Alpine/musl support unless a separate `linux-musl-*` binary is built and tested. Add other architectures only after each has native CI execution coverage.

## 5. Repository and versioning strategy

Use this repository as the platform build and packaging project; do not modify cloned upstream working trees during packaging.

Recommended layout:

```text
build.sh
mvnw
mvnw.cmd
.mvn/wrapper/
pom.xml
README.md
LICENSES/
dist/                         # generated final artifacts; not source-controlled
scripts/
  clone-sources.sh
  build-native.sh
  verify-native.sh
src/main/java/                 # unified loader; API sources if vendored
src/main/resources/native/
  linux-x86_64/libtidesdb_jni.so
  linux-aarch64/libtidesdb_jni.so
  macos-x86_64/libtidesdb_jni.dylib
  macos-aarch64/libtidesdb_jni.dylib
  windows-x86_64/tidesdb_jni.dll
src/test/java/
.github/workflows/
```

Pin immutable upstream commit SHAs in one machine-readable file (for example `upstream.properties`). Record both tags and SHAs in the generated JAR metadata. Builds may clone the repositories, but release builds must never consume floating `master`.

Choose one Java-source approach:

1. **Preferred initially:** vendor the released `tidesdb-java` sources at the pinned commit and keep a small, documented loader patch. This guarantees a genuinely standalone JAR and makes sources/Javadocs straightforward.
2. Build upstream `tidesdb-java`, then unpack/merge its classes into the unified JAR. This reduces copied source but complicates source/Javadoc artifacts and duplicate metadata.

Do not make `tidesdb-java` a runtime dependency; that would violate the single-dependency/single-JAR objective.

Use a unified artifact version that records the Java binding baseline and independently records the native TidesDB version in manifest properties. Establish a release compatibility table in the README.

## 6. Native build design

### 5.1 Build one self-contained JNI library

Create a top-level native CMake build that:

1. clones/checks out pinned TidesDB and tidesdb-java sources;
2. adds TidesDB with `BUILD_SHARED_LIBS=OFF`, `TIDESDB_BUILD_TESTS=OFF`, sanitizers off, and PIC on;
3. builds `com_tidesdb_TidesDB.c` as the sole shared JNI target;
4. links the static `tidesdb` target into `tidesdb_jni`;
5. links static zstd, lz4, and snappy libraries into that target;
6. enables no optional allocators or S3 initially, to minimize native dependencies;
7. strips release binaries only after retaining symbols/debug artifacts separately if desired.

Prefer a single CMake target graph (`add_subdirectory` or `FetchContent`) over installing TidesDB and rediscovering it with `find_library`. This avoids accidentally selecting a shared system library.

### 5.2 Compression dependencies

Use pinned dependency versions and static builds. vcpkg with locked baselines/static triplets is a reasonable cross-platform option; alternatively use CMake `FetchContent`. The selected method must:

- compile all archives with PIC where required;
- select static targets explicitly, not whichever target happens to be found first;
- include C++ runtime implications from Snappy in platform verification;
- generate license and version information for every bundled component;
- avoid host-installed compression libraries during release builds.

### 5.3 Platform-specific constraints

- **Linux:** allow normal system dependencies such as libc, libm, pthread, and the loader, but no `libtidesdb`, zstd, lz4, or snappy dependency. Build on the oldest supported distribution/container to avoid an unnecessarily high glibc floor.
- **macOS (future):** set a minimum deployment target and ensure install names do not reference Homebrew paths. Build separate architecture-specific JARs; do not create a universal JAR.
- **Windows:** prefer MSVC plus a static vcpkg triplet to avoid MinGW runtime DLLs. If MinGW is retained, statically link its required runtimes or explicitly package/load them; a lone JNI DLL must not silently depend on MSYS2 DLLs.

## 7. Java native loader

Replace/extend upstream `NativeLibrary` with a deterministic loader:

1. Normalize platform values to a closed set:
   - OS: `linux`, `macos`, `windows`
   - architecture aliases: `amd64`/`x86_64` → `x86_64`; `aarch64`/`arm64` → `aarch64`
2. Resolve `/native/<os>-<arch>/<mapped-library-name>`.
3. Fail with a clear message listing detected and supported platforms when unsupported.
4. Hash the embedded bytes (SHA-256) and extract to a versioned/hash-addressed directory, such as `${java.io.tmpdir}/tidesdb-java-unified/<version>/<sha256>/`.
5. Use an atomic temporary-file move and process-safe locking so parallel JVMs/threads cannot observe a partial file.
6. Apply executable/read permissions where needed and call `System.load` with the absolute path.
7. Keep loading idempotent and thread-safe.
8. Preserve an explicit development override (system property with an absolute library path). Optionally try `System.loadLibrary` only when the override is requested; embedded-by-default behavior is more deterministic.
9. Preserve the extracted file for process lifetime. Do not rely solely on `deleteOnExit`, which is unreliable on Windows and can accumulate registrations.
10. Retain the original `UnsatisfiedLinkError` as the cause/context and include the attempted resource and extraction path.

If Windows ultimately needs multiple DLLs, extract all of them into one directory and load dependencies in deterministic order before loading `tidesdb_jni.dll`. The preferred build outcome remains one self-contained DLL.

## 8. Single-command build and Maven assembly

The complete MVP build has one public entry point, run from the repository root:

```bash
./build.sh
```

`build.sh` must perform all required steps without requiring the user to invoke CMake, Maven, clone scripts, or validation scripts separately:

1. run a complete preflight that verifies Linux x86-64 and every required external tool before cloning or compiling anything;
2. remove any previous `dist/`, install a failure trap that cleans it, and create clean repository-local working directories so stale artifacts cannot survive;
3. clone both upstream repositories and check out the pinned immutable SHAs;
4. fetch/build pinned static compression dependencies;
5. configure and build static TidesDB;
6. build the JNI shared library with static TidesDB/compression linkage;
7. inspect and enforce the native dependency allowlist;
8. build and test the Java binding and native loader;
9. run exactly `./mvnw clean install` as the Maven build, which formats/checks, tests, packages, and installs the Linux x86-64 unified JAR containing exactly one native library into the local Maven repository;
10. run the packaged-JAR validation example from an isolated temporary Maven repository, without native path environment overrides;
11. generate checksums, dependency reports, license/SBOM/provenance metadata required by the MVP;
12. copy only successfully validated deliverables into `dist/`.

### 8.1 Robust `build.sh` requirements

The script must use `set -Eeuo pipefail`, quote all paths/variables, resolve the repository root from the script location (so it works from any current directory), print clear timestamped phase names, and preserve the failing command/line in an `ERR` trap. An `EXIT` trap must remove partial staging output and leave `dist/` absent or empty after any failed build. Build into a temporary staging directory and move artifacts into `dist/` atomically only after all validation succeeds.

Before changing source/build state, preflight must use `command -v` plus a minimal functional/version check for every required host tool. The definitive list must match the implemented build, but is expected to include:

- `bash` at the minimum version required by the script;
- `git`;
- `cmake` at the minimum required by pinned TidesDB (currently at least 3.25);
- the selected build backend, such as `ninja` (preferred) or `make`;
- `gcc`, `g++`, and the required linker/archive tools (`ld`, `ar`, and `ranlib`);
- `pkg-config` if any configured dependency build uses it;
- JDK tools `java`, `javac`, and `jar`, all from a compatible JDK 11+ installation;
- `curl` or another explicitly selected download tool if the Maven Wrapper/dependency bootstrap requires it;
- Linux inspection tools used by acceptance checks, including `readelf`, `ldd`, and `file`;
- checksum/archive utilities actually used by the scripts, such as `sha256sum`, `tar`, and `unzip`.

The checked-in `./mvnw` file is itself a required executable and must be validated, but a system `mvn` installation is neither required nor used. Preflight must also verify that Java and `javac` resolve to compatible versions, the host reports `Linux` and `x86_64`/`amd64`, the filesystem has sufficient writable space, required source pins are present, and network-dependent source locations are syntactically configured. It should detect unsupported environment overrides that could contaminate native linkage (for example unexpected compiler/linker flags or library search paths) and either sanitize them or fail explicitly.

Preflight must collect all missing or incompatible prerequisites and report them together in one actionable error rather than failing at the first missing command. The message must name each tool, the required minimum version when applicable, and state that `build.sh` does not install prerequisites. It must exit nonzero before cloning/building and must not use `sudo`, `apt`, `brew`, or another package manager.

For robustness and repeatability, `build.sh` must additionally:

- support a clean rerun after success, interruption, or failure without consuming stale native objects;
- use repository-local, uniquely named work/staging directories and prevent concurrent builds from corrupting them (lock or fail clearly);
- validate every `cd`, clone checkout SHA, downloaded checksum, expected output path, and copy/move operation;
- pass explicit source/build paths and build type to CMake rather than relying on ambient state;
- use a bounded, configurable parallelism value with a safe default;
- avoid logging secrets or the complete environment;
- emit a concise final artifact/checksum summary on success;
- return distinct, documented failure context for preflight, native build, Maven build, dependency audit, and packaged-JAR validation phases.

The main-project Maven invocation in `build.sh` must be exactly `./mvnw clean install`; subsequent helper/example Maven invocations must also use `./mvnw`, never `mvn` from `PATH`. The build must not install files into `/usr/local`, require `sudo`, or depend on a preinstalled TidesDB/compression library. Internal scripts under `scripts/` remain implementation details invoked by `build.sh`.

On success, the primary deliverable must be:

```text
dist/tidesdb-java-unified-<version>-linux-x86_64.jar
```

`dist/` may also contain the sources/Javadoc JARs, SHA-256 checksums, SBOM, provenance, and native dependency report. The root `README.md` should document `./build.sh` as the only required build command.

Create a normal Java 11 Maven project with the Maven Wrapper committed to the repository. The canonical Maven build is:

```bash
./mvnw clean install
```

Configure `com.diffplug.spotless:spotless-maven-plugin` with `palantirJavaFormat()` using the latest available Palantir Java Format release at implementation time. Resolve the latest versions once when the project is created, record and pin both the Spotless plugin and formatter versions in `pom.xml`, and update them deliberately rather than resolving floating versions during builds. Bind `spotless:check` to an early lifecycle phase so `./mvnw clean install` fails on formatting violations. Provide `./mvnw spotless:apply` as the documented developer command for fixing formatting. Formatting must cover all maintained Java sources, including tests and the validation example where supported by the project layout.

On Linux x86-64, the MVP produces one final platform-specific binary JAR, for example:

- `tidesdb-java-unified-<version>-linux-x86_64.jar`
- sources JAR
- Javadoc JAR
- checksums for local/CI verification

The exact future Maven classifier/coordinate convention can be finalized when publishing is designed. For the MVP, the filename and manifest must identify `linux-x86_64`; there is no repository publication step. Maven output under `target/` is intermediate—the validated deliverable is always copied to `dist/` by `build.sh`.

Each platform CI job must compile its own native binary and package its own final JAR in that same job. A job must never download another platform's native binary or combine native resources. The JAR contains exactly one platform resource, such as `/native/linux-x86_64/libtidesdb_jni.so` for the MVP.

Add build-time checks that:

- the detected build platform equals the requested artifact platform;
- exactly one native resource exists and it matches the build platform;
- the filename, manifest metadata, and resource classifier agree;
- no duplicate classes/resources are introduced when merging upstream Java output;
- the JAR contains provenance, licenses, upstream SHAs, and the native checksum;
- builds use pinned upstream refs.

For reproducibility, pin the JDK, Maven Wrapper distribution, Maven plugin versions (including Spotless), Palantir Java Format version, CMake/toolchain images, vcpkg baseline/dependency versions, timestamps, and archive ordering where practical.

## 9. CI/CD pipeline

### Stage A — source/API compatibility

- Checkout this repository.
- Invoke `./build.sh`; CI must exercise the same entry point used by developers, and the script must execute `./mvnw clean install`.
- Through `build.sh`, clone both upstream repositories at pinned SHAs.
- Compile the Java binding against the selected TidesDB headers.
- Fail early on JNI/API incompatibility.

### Stage B — platform-native build

For the current job's platform/architecture (Linux x86-64 for the MVP):

- reject a build-host/target mismatch;
- build static TidesDB and static third-party dependencies;
- build the shared JNI wrapper;
- run native dependency inspection;
- run a Java smoke/integration test using the unpackaged native binary.

### Stage C — platform-specific JAR

In the same platform job:

- place only that platform's native output under its canonical resource path;
- build source, Javadoc, and platform-specific binary JARs;
- inspect JAR contents and verify the native checksum and platform metadata;
- retain the candidate JAR as a CI artifact.

There is no cross-platform assembly job and no universal JAR.

### Stage D — packaged runtime tests

Run that platform's final JAR on the same target platform in a clean machine/container with:

- no TidesDB/compression packages installed;
- no `java.library.path` customization;
- no source/build directory available;
- a small database lifecycle test: open, create column family, put, get, iterate, close, reopen, verify, delete;
- compression tests for every bundled algorithm;
- concurrent calls to `NativeLibrary.load()`;
- paths containing spaces and non-ASCII characters;
- two separate JVMs starting simultaneously against the extraction cache.

### 9.1 Crash-safe, process-safe native cache publication

The hash-addressed cache is shared by JVMs, so extraction must coordinate at the
operating-system process level rather than relying only on the loader's
`ReentrantLock`:

1. Create the version/hash cache directory before inspecting the destination.
2. Open a persistent `.extract.lock` file in that directory and acquire an
   exclusive `FileChannel` lock. Never delete the lock file, because replacing
   it could let processes lock different filesystem objects.
3. After acquiring the lock, revalidate the final library with SHA-256. This
   second check closes the check-then-act race.
4. If missing or corrupt, write the embedded bytes to a unique temporary file in
   the same directory, set permissions, force its file contents to stable
   storage, and atomically replace the final path.
5. Always remove the temporary file when possible and release the process lock.
   A crash before publication may leave only an ignored `.tmp-*` file; a crash
   after atomic publication leaves the complete library.
6. Load only the validated final path after releasing the extraction lock.

Retain one content-addressed library per artifact hash rather than generating a
copy per JVM. Validate recovery from a corrupt/partial final file, tolerance of
an abandoned temporary file, and simultaneous publication by separate JVMs.

### Stage E — MVP artifact retention

- retain the tested Linux x86-64 JAR, checksum, SBOM, dependency report, and provenance as CI artifacts;
- test the JAR from a fresh sample Maven project using a local/temporary repository;
- do not publish to Maven Central or any other package repository during the MVP.

## 10. Native dependency acceptance checks

Automate these checks and fail the build when bundled libraries remain dynamically referenced:

- Linux: `readelf -d`, `ldd`, and symbol/version inspection.
- macOS: `otool -L` and deployment-target inspection.
- Windows: `dumpbin /DEPENDENTS` (or `llvm-objdump -p`).

Allowed dependency lists must be explicit per platform. Specifically reject references to `tidesdb`, `zstd`, `lz4`, `snappy`, Homebrew, MSYS2, vcpkg build directories, or CI workspace paths. Also scan RPATH/RUNPATH/install-name entries.

## 11. Testing layers

1. **Formatting gate:** `./mvnw clean install` runs Spotless with pinned latest-at-implementation Palantir Java Format and rejects unformatted Java.
2. **Loader unit tests:** OS/architecture aliases, unsupported platforms, missing resource, checksum mismatch, concurrent extraction, and useful errors.
3. **JNI integration tests:** reuse the upstream Java test suite against each native build.
4. **Packaged-JAR tests:** execute only with the final JAR on the classpath.
5. **Compatibility tests:** Java 11 plus current LTS JDKs (17, 21, and 25 where available).
6. **Release audit:** licenses, SBOM, dependency reports, binary checksums, and clean-machine execution.

Native tests must run on the target architecture; cross-compilation alone is not sufficient acceptance evidence.

## 11.1 Maven version auditing

Maintain every direct dependency and build-plugin version as a named property in
`pom.xml`, grouped into dependency and plugin versions. Configure the MojoHaus
Versions Maven Plugin with a repository-root `versions-rules.xml`, following the
AltContainers pattern. The rules shall reject alpha, beta, milestone, release
candidate, early-access, and snapshot releases so routine audits recommend only
stable versions.

Developers shall run the checked-in wrapper, never a system Maven executable:

```bash
./mvnw versions:display-property-updates
./mvnw versions:display-plugin-updates
```

Apply stable updates deliberately, preserving Java 11 runtime/source
compatibility (including JUnit Jupiter 5 rather than JUnit 6), then run
`./build.sh`. Because `build.sh` invokes `./mvnw clean install`, successful
verification must also install the artifact into the normal local Maven
repository.

### 11.2 Standard Maven Wrapper

Use the same checked-in binary-wrapper model as AltContainers: standard Maven
Wrapper launchers, `.mvn/wrapper/maven-wrapper.jar`, `distributionType=bin`, and
a pinned stable Maven distribution URL. Generate these files with the wrapper
plugin rather than maintaining custom download/extraction logic. Keep both Unix
and Windows launchers, preserve executable permission on `mvnw`, and continue to
route every project, example, version-audit, and release Maven invocation through
`./mvnw` (or `mvnw.cmd` on Windows). Verify the wrapper-reported Maven version
and the complete `./build.sh` workflow.

## 12. Licensing and security

- Preserve MPL-2.0 notices for TidesDB and tidesdb-java.
- Bundle notices/licenses for Snappy, LZ4, zstd, xxHash, and any tool/runtime code statically included.
- Generate an SBOM for Java and native components.
- Pin source commits and verify downloaded archives/checksums.
- Use least-privilege release credentials and artifact attestations.
- Document that extraction executes native code and explain the cache location and override property.

Before any future publication, confirm whether distributing modified/vendored upstream Java sources requires any additional source-notice workflow under MPL-2.0.

## 13. Delivery milestones

### Milestone 1 — Linux x86_64 proof of concept

- Pin and clone both upstream repositories.
- Build a self-contained Linux JNI `.so`.
- Implement normalized extraction/loading.
- Implement `./build.sh` as the sole end-to-end build entry point.
- Produce the final platform-specific JAR under `dist/` and pass clean-container lifecycle/compression tests.
- Prove via `readelf`/`ldd` that compression and TidesDB are not external dependencies.

**Exit criterion:** a sample project needs only the unified Maven dependency and no machine-level TidesDB installation.

### Milestone 2 — additional platform-specific artifacts

- Add Linux ARM64, macOS Intel/ARM64, and Windows x64 individually.
- Have every platform build, test, and retain its own final JAR.
- Add target-native tests and dependency allowlists.
- Resolve deployment baselines and Windows runtime strategy.

**Exit criterion:** every supported platform produces a separate JAR built and executed on its target architecture; no universal artifact is assembled.

### Milestone 3 — release-quality artifact

- Add sources/Javadocs, licenses, SBOM, provenance, reproducible assembly checks, and sample Maven/Gradle projects.
- Run the upstream test suite and packaged-JAR tests across supported JDKs.

**Exit criterion:** signed staging artifact passes all audits and fresh-project tests.

### Milestone 4 — optional future publishing and maintenance

- Design platform classifier/artifact coordinates before any repository publication.
- Publish platform-specific artifacts only if publishing is later approved.
- Add automated upstream update PRs that update pins and run the full compatibility matrix.
- Define support/deprecation policy and release cadence.

## 14. Decisions required before implementation

1. Minimum Linux/glibc baseline for the Linux x86-64 MVP.
2. vcpkg versus FetchContent for pinned static compression libraries.
3. Vendored Java sources versus merged upstream Java artifact (vendored sources recommended initially).
4. Whether S3 support is in scope; default recommendation is no for the MVP because static curl and its transitive TLS dependencies greatly increase complexity.
5. MVP artifact version and exact local filename convention; publication coordinates/classifiers are deferred.
6. Whether system-installed native library fallback remains supported or embedded-native loading is mandatory by default.
7. Future only: exact additional platform list and MSVC versus MinGW for Windows.
