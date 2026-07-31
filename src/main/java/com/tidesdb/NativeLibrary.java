/**
 *
 * Copyright (C) TidesDB
 *
 * Original Author: Alex Gaetano Padula
 *
 * Licensed under the Mozilla Public License, v. 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.mozilla.org/MPL/2.0/
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.tidesdb;

import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermission;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Loads the platform-appropriate native TidesDB JNI library.
 *
 * <p>The libraries are embedded as classpath resources under {@code /native/<os>-<arch>/}. Two
 * shared libraries are packaged: {@code libtidesdb.so} (the TidesDB core engine) and {@code
 * libtidesdb_jni.so} (the Java Native Interface bridge). At load time both resources are extracted
 * to a versioned, hash-addressed cache directory under {@code java.io.tmpdir} and loaded via {@link
 * System#load(String)}.
 *
 * <p>Loading is idempotent and thread-safe. A development override for the JNI bridge is available
 * via system property {@code tidesdb.native.library.path}.
 */
public final class NativeLibrary {

  private static final String PROPERTY_OVERRIDE = "tidesdb.native.library.path";
  private static final String CACHE_DIR_PREFIX = "tidesdb-java-unified";
  private static final String NATIVE_RESOURCE_PREFIX = "/native/";

  /** Libraries to load, in dependency order (TidesDB core before JNI bridge). */
  private static final String[] NATIVE_LIBS = {"libtidesdb.so", "libtidesdb_jni.so"};

  private static volatile Boolean loaded;
  private static final ReentrantLock LOAD_LOCK = new ReentrantLock();

  private NativeLibrary() {}

  /**
   * Loads the native libraries if they have not already been loaded.
   *
   * @throws UnsatisfiedLinkError if loading fails
   */
  public static void load() {
    if (isLoaded()) {
      return;
    }
    LOAD_LOCK.lock();
    try {
      if (isLoaded()) {
        return;
      }
      doLoad();
      loaded = true;
    } finally {
      LOAD_LOCK.unlock();
    }
  }

  /** Returns {@code true} if the native library has been successfully loaded. */
  public static boolean isLoaded() {
    return loaded != null && loaded;
  }

  private static void doLoad() {
    // 1. Check development override (loads a single library, no embedded extraction)
    String override = System.getProperty(PROPERTY_OVERRIDE);
    if (override != null && !override.isBlank()) {
      Path path = Paths.get(override.trim());
      if (!Files.isRegularFile(path)) {
        throw new UnsatisfiedLinkError(
            "Native library override path does not exist: " + path);
      }
      System.load(path.toAbsolutePath().toString());
      return;
    }

    // 2. Determine platform classifier
    String os = normalizeOs(System.getProperty("os.name"));
    String arch = normalizeArch(System.getProperty("os.arch"));
    String classifier = os + "-" + arch;

    // 3. Read all embedded libraries and compute their SHA-256 hashes
    List<LibEntry> entries = new ArrayList<>(NATIVE_LIBS.length);
    for (String libName : NATIVE_LIBS) {
      String resourcePath = NATIVE_RESOURCE_PREFIX + classifier + "/" + libName;
      byte[] libBytes;
      try (InputStream in = NativeLibrary.class.getResourceAsStream(resourcePath)) {
        if (in == null) {
          throw new UnsatisfiedLinkError(
              "Embedded native library not found for platform '"
                  + classifier
                  + "'. Resource: "
                  + resourcePath);
        }
        libBytes = in.readAllBytes();
      } catch (IOException e) {
        UnsatisfiedLinkError err =
            new UnsatisfiedLinkError("Failed to read embedded native library: " + resourcePath);
        err.initCause(e);
        throw err;
      }
      entries.add(new LibEntry(libName, libBytes, sha256Hex(libBytes)));
    }

    // 4. Use the SHA-256 of the JNI library as the cache subdirectory so both
    //    .so files end up in the same directory (libtidesdb_jni.so depends on
    //    libtidesdb.so and needs to find it via the dynamic linker).
    String cacheKey = entries.get(entries.size() - 1).sha256;
    String version = version();
    Path cacheDir =
        Paths.get(System.getProperty("java.io.tmpdir"), CACHE_DIR_PREFIX, version, cacheKey);

    // 5. Extract all libraries into the shared cache directory
    try {
      for (LibEntry entry : entries) {
        extract(cacheDir, entry.name, entry.bytes, entry.sha256);
      }
    } catch (IOException e) {
      UnsatisfiedLinkError err =
          new UnsatisfiedLinkError("Failed to extract native libraries to: " + cacheDir);
      err.initCause(e);
      throw err;
    }

    // 6. Load in dependency order (TidesDB core first, then JNI bridge)
    for (LibEntry entry : entries) {
      Path libPath = cacheDir.resolve(entry.name);
      try {
        System.load(libPath.toAbsolutePath().toString());
      } catch (UnsatisfiedLinkError e) {
        UnsatisfiedLinkError err =
            new UnsatisfiedLinkError(
                "Failed to load native library: "
                    + libPath
                    + " (resource: "
                    + NATIVE_RESOURCE_PREFIX
                    + classifier
                    + "/"
                    + entry.name
                    + ")");
        err.initCause(e);
        throw err;
      }
    }
  }

  // ----  Platform normalization ----

  static String normalizeOs(String osName) {
    String lower = osName.toLowerCase(Locale.ROOT);
    if (lower.contains("linux")) return "linux";
    if (lower.contains("mac") || lower.contains("darwin")) return "macos";
    if (lower.contains("windows")) return "windows";
    throw new UnsatisfiedLinkError(
        "Unsupported operating system: " + osName + ". Supported: Linux, macOS, Windows.");
  }

  static String normalizeArch(String osArch) {
    String lower = osArch.toLowerCase(Locale.ROOT);
    if (lower.matches("^(amd64|x86_64|x64)$")) return "x86_64";
    if (lower.matches("^(aarch64|arm64)$")) return "aarch64";
    throw new UnsatisfiedLinkError(
        "Unsupported architecture: " + osArch + ". Supported: x86_64, aarch64.");
  }

  static String mapLibraryName(String os) {
    switch (os) {
      case "linux":
        return "libtidesdb_jni.so";
      case "macos":
        return "libtidesdb_jni.dylib";
      case "windows":
        return "tidesdb_jni.dll";
      default:
        throw new AssertionError("unreachable");
    }
  }

  // ----  Extraction (process-safe, crash-safe) ----

  /** Publishes validated bytes into a cache shared by independent JVMs. */
  static Path extract(Path cacheDir, String libName, byte[] libBytes, String sha256Hex)
      throws IOException {
    Files.createDirectories(cacheDir);
    Path libPath = cacheDir.resolve(libName);
    Path lockPath = cacheDir.resolve(".extract.lock");

    // Keep the lock file permanently: deleting it could let waiters lock different inodes.
    try (FileChannel lockChannel =
            FileChannel.open(lockPath, StandardOpenOption.CREATE, StandardOpenOption.WRITE);
        FileLock ignored = lockChannel.lock()) {
      // Recheck only after acquiring the process lock to close the check-then-act race.
      if (Files.notExists(libPath) || !sha256Hex.equals(sha256File(libPath))) {
        Path tmpPath = Files.createTempFile(cacheDir, ".tmp-", "." + libName);
        try {
          try (FileChannel output =
              FileChannel.open(
                  tmpPath, StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING)) {
            ByteBuffer bytes = ByteBuffer.wrap(libBytes);
            while (bytes.hasRemaining()) {
              output.write(bytes);
            }
            output.force(true);
          }
          setExecutablePermissions(tmpPath);
          Files.move(
              tmpPath,
              libPath,
              StandardCopyOption.ATOMIC_MOVE,
              StandardCopyOption.REPLACE_EXISTING);
        } finally {
          try {
            Files.deleteIfExists(tmpPath);
          } catch (IOException ignoredDeleteFailure) {
            // A stale uniquely named temporary file is harmless and ignored.
          }
        }
      }
    }
    return libPath;
  }

  // ----  Utility ----

  private static String version() {
    String v = NativeLibrary.class.getPackage().getImplementationVersion();
    return v != null ? v : "dev";
  }

  private static String sha256Hex(byte[] data) {
    try {
      MessageDigest md = MessageDigest.getInstance("SHA-256");
      byte[] hash = md.digest(data);
      StringBuilder sb = new StringBuilder(64);
      for (byte b : hash) {
        sb.append(String.format("%02x", b));
      }
      return sb.toString();
    } catch (NoSuchAlgorithmException e) {
      throw new RuntimeException("SHA-256 not available", e);
    }
  }

  private static String sha256File(Path path) throws IOException {
    return sha256Hex(Files.readAllBytes(path));
  }

  private static void setExecutablePermissions(Path path) throws IOException {
    try {
      Set<PosixFilePermission> perms =
          EnumSet.of(
              PosixFilePermission.OWNER_READ,
              PosixFilePermission.OWNER_WRITE,
              PosixFilePermission.OWNER_EXECUTE);
      Files.setPosixFilePermissions(path, perms);
    } catch (UnsupportedOperationException ignored) {
      // Windows — permissions handled differently
    }
  }

  /** Internal record holding a library's name, bytes, and SHA-256 hash. */
  private static final class LibEntry {
    final String name;
    final byte[] bytes;
    final String sha256;

    LibEntry(String name, byte[] bytes, String sha256) {
      this.name = name;
      this.bytes = bytes;
      this.sha256 = sha256;
    }
  }
}
