package com.example.o2a.capture;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

/**
 * Loads the capture configuration and turns it into the Debezium embedded
 * engine property set (spec C2).
 *
 * <p>Values come from a properties file; any value may be overridden by an
 * environment variable of the same name in upper snake case
 * ({@code database.hostname} → {@code DATABASE_HOSTNAME}), which is how
 * docker-compose injects the container-vs-host difference without editing
 * a file — the same problem the migration lab solved with {@code ORACLE_HOST}.
 */
public final class CaptureConfig {

    private final Properties props = new Properties();

    private CaptureConfig() {
    }

    public static CaptureConfig load(Path file) throws IOException {
        CaptureConfig cfg = new CaptureConfig();
        try (InputStream in = Files.newInputStream(file)) {
            cfg.props.load(in);
        }
        cfg.applyEnvironmentOverrides();
        return cfg;
    }

    private void applyEnvironmentOverrides() {
        for (String name : props.stringPropertyNames()) {
            String env = name.toUpperCase().replace('.', '_').replace('-', '_');
            String value = System.getenv(env);
            if (value != null && !value.isBlank()) {
                props.setProperty(name, value);
            }
        }
    }

    public String get(String key) {
        String v = props.getProperty(key);
        if (v == null || v.isBlank()) {
            throw new IllegalStateException("missing required config key: " + key);
        }
        return v;
    }

    public String get(String key, String defaultValue) {
        String v = props.getProperty(key);
        return (v == null || v.isBlank()) ? defaultValue : v;
    }

    public int getInt(String key, int defaultValue) {
        return Integer.parseInt(get(key, Integer.toString(defaultValue)));
    }

    /**
     * Builds the Debezium engine properties.
     *
     * <p>Notes on the non-obvious entries:
     * <ul>
     *   <li>{@code database.dbname} is the CDB ROOT ({@code FREE}) while the
     *       tables live in the PDB — mining happens at the root. Spike S2
     *       confirmed {@code SRC_CON_NAME=FREEPDB1} in that arrangement.</li>
     *   <li>{@code provide.transaction.metadata} is REQUIRED, not optional:
     *       decision D4 groups row events by transaction and only releases a
     *       batch once the END marker's counts match what was buffered.</li>
     *   <li>{@code snapshot.mode=no_data} because the migration lab already did the bulk
     *       load; a snapshot here would re-emit ~1,900 records as changes.</li>
     * </ul>
     */
    public Properties toDebeziumProperties() {
        Properties p = new Properties();

        p.setProperty("name", get("capture.name", "o2a-oracle-capture"));
        p.setProperty("connector.class", "io.debezium.connector.oracle.OracleConnector");
        p.setProperty("topic.prefix", get("topic.prefix", "o2a"));

        p.setProperty("database.hostname", get("database.hostname"));
        p.setProperty("database.port", get("database.port", "1521"));
        p.setProperty("database.user", get("database.user"));
        p.setProperty("database.password", get("database.password"));
        p.setProperty("database.dbname", get("database.dbname"));
        p.setProperty("database.pdb.name", get("database.pdb.name"));

        p.setProperty("table.include.list", get("table.include.list"));
        p.setProperty("snapshot.mode", get("snapshot.mode", "no_data"));
        // snapshot.mode=no_data still takes a SCHEMA snapshot, and that path
        // issues LOCK TABLE ... IN ROW SHARE MODE on every included table.
        // Without this the connector dies on startup with ORA-41900
        // (missing LOCK privilege). Granting LOCK ANY TABLE would also work
        // but hands the capture user a privilege it has no business holding -
        // and that is a conversation with the DBA we do not need to have.
        // Locking exists to freeze data during a data snapshot; we take none.
        p.setProperty("snapshot.locking.mode", get("snapshot.locking.mode", "none"));
        p.setProperty("provide.transaction.metadata", "true");

        // Offsets and schema history are plain files: no Kafka, no broker
        // (decision D2). The offset file is the restart watermark on the
        // capture side, mirroring the Adabas ledger on the apply side.
        p.setProperty("offset.storage",
                "org.apache.kafka.connect.storage.FileOffsetBackingStore");
        p.setProperty("offset.storage.file.filename", get("offset.storage.file.filename"));
        p.setProperty("offset.flush.interval.ms", get("offset.flush.interval.ms", "5000"));

        p.setProperty("schema.history.internal",
                "io.debezium.storage.file.history.FileSchemaHistory");
        p.setProperty("schema.history.internal.file.filename",
                get("schema.history.internal.file.filename"));

        // Keep values as plain JSON without Avro-style schema envelopes -
        // the assembler only needs the payload.
        p.setProperty("key.converter.schemas.enable", "false");
        p.setProperty("value.converter.schemas.enable", "false");

        // Emit numeric columns as plain numbers rather than Kafka Connect's
        // base64-encoded org.apache.kafka.connect.data.Decimal, which would
        // otherwise turn EMP_ID into an opaque string.
        p.setProperty("decimal.handling.mode", get("decimal.handling.mode", "double"));

        for (String name : props.stringPropertyNames()) {
            if (name.startsWith("debezium.")) {
                p.setProperty(name.substring("debezium.".length()), props.getProperty(name));
            }
        }
        return p;
    }
}
