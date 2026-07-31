package com.tidesdb;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.api.io.TempDir;

class NativeLibraryTest {

  @TempDir Path tempDir;

  @Test
  void normalizesOperatingSystems() {
    assertThat(NativeLibrary.normalizeOs("Linux")).isEqualTo("linux");
    assertThat(NativeLibrary.normalizeOs("GNU/Linux")).isEqualTo("linux");
    assertThat(NativeLibrary.normalizeOs("Darwin")).isEqualTo("macos");
    assertThat(NativeLibrary.normalizeOs("Windows 10")).isEqualTo("windows");
    assertThatThrownBy(() -> NativeLibrary.normalizeOs("FreeBSD"))
        .isInstanceOf(UnsatisfiedLinkError.class);
  }

  @Test
  void normalizesArchitectures() {
    assertThat(NativeLibrary.normalizeArch("amd64")).isEqualTo("x86_64");
    assertThat(NativeLibrary.normalizeArch("x64")).isEqualTo("x86_64");
    assertThat(NativeLibrary.normalizeArch("arm64")).isEqualTo("aarch64");
    assertThatThrownBy(() -> NativeLibrary.normalizeArch("ppc64le"))
        .isInstanceOf(UnsatisfiedLinkError.class);
  }

  @Test
  void mapsLibraryNames() {
    assertThat(NativeLibrary.mapLibraryName("linux")).isEqualTo("libtidesdb_jni.so");
    assertThat(NativeLibrary.mapLibraryName("macos")).isEqualTo("libtidesdb_jni.dylib");
    assertThat(NativeLibrary.mapLibraryName("windows")).isEqualTo("tidesdb_jni.dll");
  }

  @Test
  void repairsPartialFinalFileAndIgnoresAbandonedTemporaryFile() throws Exception {
    byte[] expected = "complete native library".getBytes(StandardCharsets.UTF_8);
    Path cache = tempDir.resolve("cache");
    Files.createDirectories(cache);
    Path library = cache.resolve("libtest.so");
    Path abandoned = cache.resolve(".tmp-abandoned.libtest.so");
    Files.write(library, new byte[] {1, 2, 3});
    Files.write(abandoned, new byte[] {4, 5, 6});

    assertThat(NativeLibrary.extract(cache, "libtest.so", expected, sha256(expected)))
        .hasBinaryContent(expected);
    assertThat(abandoned).exists().hasBinaryContent(new byte[] {4, 5, 6});
    assertThat(cache.resolve(".extract.lock")).exists();
  }

  @Test
  void twoJvmProcessesPublishTheSameCompleteFile() throws Exception {
    byte[] expected = "shared process-safe native library".getBytes(StandardCharsets.UTF_8);
    Path cache = tempDir.resolve("shared-cache");
    String classPath = System.getProperty("java.class.path");
    String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
    List<Process> processes = new ArrayList<>();

    for (int i = 0; i < 4; i++) {
      processes.add(
          new ProcessBuilder(
                  java,
                  "-cp",
                  classPath,
                  NativeLibraryExtractionProcess.class.getName(),
                  cache.toString(),
                  "libtest.so",
                  new String(expected, StandardCharsets.UTF_8))
              .redirectErrorStream(true)
              .start());
    }

    for (Process process : processes) {
      int exitCode = process.waitFor();
      String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
      assertThat(exitCode).withFailMessage(output).isZero();
    }
    assertThat(cache.resolve("libtest.so")).hasBinaryContent(expected);
  }

  @Test
  @EnabledOnOs(OS.LINUX)
  void loadsIdempotentlyAndConcurrently() throws Exception {
    Thread[] threads = new Thread[10];
    for (int i = 0; i < threads.length; i++) threads[i] = new Thread(NativeLibrary::load);
    for (Thread thread : threads) thread.start();
    for (Thread thread : threads) thread.join();
    NativeLibrary.load();
    assertThat(NativeLibrary.isLoaded()).isTrue();
  }

  static String sha256(byte[] bytes) throws Exception {
    byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
    StringBuilder result = new StringBuilder(64);
    for (byte value : digest) result.append(String.format("%02x", value));
    return result.toString();
  }
}
