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
    }
}
