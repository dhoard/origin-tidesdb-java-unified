package com.tidesdb;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * Integration test requiring the final platform-specific JAR with embedded native library on the
 * classpath. No {@code -Djava.library.path}.
 */
class PackagedJarIT {

  @TempDir Path tempDir;

  @Test
  void fullLifecycle() throws Exception {
    NativeLibrary.load();
    assertTrue(NativeLibrary.isLoaded());

    byte[] key = "hello".getBytes(StandardCharsets.UTF_8);
    byte[] expected = "tidesdb-java-unified".getBytes(StandardCharsets.UTF_8);

    Config config =
        Config.builder(tempDir.resolve("db").toString())
            .numFlushThreads(1)
            .numCompactionThreads(1)
            .logLevel(LogLevel.INFO)
            .blockCacheSize(16 * 1024 * 1024)
            .maxOpenSSTables(64)
            .build();

    try (TidesDB db = TidesDB.open(config)) {
      db.createColumnFamily("test", ColumnFamilyConfig.defaultConfig());
      ColumnFamily cf = db.getColumnFamily("test");
      try (Transaction txn = db.beginTransaction()) {
        txn.put(cf, key, expected);
        txn.commit();
      }
    }

    try (TidesDB db = TidesDB.open(config)) {
      ColumnFamily cf = db.getColumnFamily("test");
      try (Transaction txn = db.beginTransaction()) {
        byte[] actual = txn.get(cf, key);
        assertArrayEquals(expected, actual);
      }
    }
  }

  @Test
  void pathsWithSpaces(@TempDir Path baseDir) throws Exception {
    Path dirWithSpaces = baseDir.resolve("tidesdb data with spaces");
    NativeLibrary.load();

    Config config =
        Config.builder(dirWithSpaces.toString()).numFlushThreads(1).logLevel(LogLevel.INFO).build();

    try (TidesDB db = TidesDB.open(config)) {
      db.createColumnFamily("cf", ColumnFamilyConfig.defaultConfig());
      assertNotNull(db.getColumnFamily("cf"));
    }
  }
}
