/**
 * TidesDB Java Unified module.
 *
 * <p>This module exports the {@code com.tidesdb} package, which contains the
 * {@link com.tidesdb.NativeLibrary} loader as well as all upstream
 * tidesdb-java API classes (merged at build time by the shade plugin).
 *
 * <p>Native library loading via {@code System.load()} requires the
 * {@code --enable-native-access=com.tidesdb} JVM flag on JDK 16+.
 */
module com.tidesdb {
    exports com.tidesdb;
}
