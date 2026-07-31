package com.tidesdb;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;

/** Subprocess entry point used to verify operating-system-level extraction locking. */
public final class NativeLibraryExtractionProcess {
  private NativeLibraryExtractionProcess() {}

  public static void main(String[] args) throws Exception {
    byte[] bytes = args[2].getBytes(StandardCharsets.UTF_8);
    NativeLibrary.extract(Path.of(args[0]), args[1], bytes, NativeLibraryTest.sha256(bytes));
  }
}
