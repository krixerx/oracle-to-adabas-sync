package com.example.o2a.capture;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.debezium.engine.ChangeEvent;
import io.debezium.engine.DebeziumEngine;
import io.debezium.engine.format.Json;

import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Gating spike S3: does the Debezium Oracle connector work against
 * Oracle 23ai Free in a CDB/PDB arrangement, and does it emit the
 * transaction BEGIN/END metadata that decision D4 depends on?
 *
 * <p>Prints every event it receives and, at the end, a verdict. It is a
 * spike, not the capture service — it deliberately keeps everything in
 * memory and exits on a timer. {@link CaptureMain} is the real thing.
 *
 * <p>Usage: {@code java -cp oracle-capture.jar com.example.o2a.capture.SpikeS3Main
 * <config.properties> [seconds]}
 */
public final class SpikeS3Main {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: SpikeS3Main <config.properties> [seconds]");
            System.exit(2);
        }
        int seconds = args.length > 1 ? Integer.parseInt(args[1]) : 90;

        CaptureConfig cfg = CaptureConfig.load(Path.of(args[0]));
        Properties props = cfg.toDebeziumProperties();

        System.out.println("=== Spike S3: Debezium Oracle connector vs 23ai Free ===");
        System.out.println("  database.dbname   = " + props.getProperty("database.dbname") + "   (CDB root)");
        System.out.println("  database.pdb.name = " + props.getProperty("database.pdb.name"));
        System.out.println("  tables            = " + props.getProperty("table.include.list"));
        System.out.println("  listening for " + seconds + "s — make changes in Oracle now");
        System.out.println();

        List<String> dataEvents = new ArrayList<>();
        List<String> txBegin = new ArrayList<>();
        List<String> txEnd = new ArrayList<>();
        AtomicBoolean sawEnrichedTx = new AtomicBoolean(false);
        java.util.concurrent.CountDownLatch stopped = new java.util.concurrent.CountDownLatch(1);

        DebeziumEngine<ChangeEvent<String, String>> engine =
                DebeziumEngine.create(Json.class)
                        .using(props)
                        .notifying(record -> {
                            try {
                                handle(record, dataEvents, txBegin, txEnd, sawEnrichedTx);
                            } catch (Exception e) {
                                System.err.println("  !! failed to parse event: " + e);
                            }
                        })
                        .using((success, message, error) -> {
                            System.out.println("--- engine stopped: success=" + success
                                    + " message=" + message);
                            if (error != null) {
                                error.printStackTrace(System.err);
                            }
                            stopped.countDown();
                        })
                        .build();

        ExecutorService executor = Executors.newSingleThreadExecutor();
        executor.execute(engine);

        // Wait for the deadline OR for the engine to die, whichever comes
        // first. Plain sleep-then-close hangs for the full run duration when
        // the connector fails at startup, and the eventual close() can block
        // too - a failed capture that hangs is worse than one that crashes,
        // because it looks alive to any supervisor watching the process.
        boolean died = stopped.await(seconds, TimeUnit.SECONDS);
        if (died) {
            System.out.println("--- engine terminated early; stopping the spike ---");
        }
        try {
            engine.close();
        } catch (Exception e) {
            System.err.println("engine.close() failed: " + e);
        }
        executor.shutdownNow();
        executor.awaitTermination(30, TimeUnit.SECONDS);

        System.out.println();
        System.out.println("=== S3 RESULT ===");
        report("connector emitted data change events", !dataEvents.isEmpty(),
                dataEvents.size() + " events");
        report("transaction BEGIN markers present", !txBegin.isEmpty(),
                txBegin.size() + " markers");
        report("transaction END markers present (D4 depends on this)", !txEnd.isEmpty(),
                txEnd.size() + " markers");
        report("data events carry transaction id (grouping key)", sawEnrichedTx.get(),
                sawEnrichedTx.get() ? "transaction block present" : "MISSING");

        boolean pass = !dataEvents.isEmpty() && !txBegin.isEmpty()
                && !txEnd.isEmpty() && sawEnrichedTx.get();
        System.out.println(pass ? "S3 PASSED" : "S3 FAILED");
        System.exit(pass ? 0 : 1);
    }

    private static void handle(ChangeEvent<String, String> record,
                               List<String> dataEvents,
                               List<String> txBegin,
                               List<String> txEnd,
                               AtomicBoolean sawEnrichedTx) throws Exception {
        String value = record.value();
        if (value == null) {
            return; // tombstone
        }
        JsonNode node = MAPPER.readTree(value);

        // Transaction metadata events land on <topic.prefix>.transaction and
        // carry a "status" field instead of an op/before/after envelope.
        JsonNode status = node.path("status");
        if (!status.isMissingNode()) {
            String id = node.path("id").asText();
            if ("BEGIN".equals(status.asText())) {
                txBegin.add(id);
                System.out.println("  TX BEGIN  id=" + id);
            } else {
                txEnd.add(id);
                System.out.println("  TX END    id=" + id
                        + " event_count=" + node.path("event_count").asInt()
                        + " collections=" + node.path("data_collections"));
            }
            return;
        }

        // Schema-change events share the stream but carry a `ddl`/`tableChanges`
        // payload instead of an op/before/after envelope. They are how the
        // connector records DDL, not row changes - counting them as data
        // events would make the spike pass on schema alone.
        if (node.path("op").isMissingNode()) {
            System.out.println("  SCHEMA  " + node.path("source").path("table").asText("?")
                    + " (not a row change)");
            return;
        }

        String op = node.path("op").asText("?");
        String table = node.path("source").path("table").asText("?");
        String scn = node.path("source").path("scn").asText("?");
        String user = node.path("source").path("user_name").asText("");
        String txId = node.path("transaction").path("id").asText("");
        if (!txId.isEmpty()) {
            sawEnrichedTx.set(true);
        }
        dataEvents.add(table + "/" + op);
        System.out.println("  DATA op=" + op + " table=" + table
                + " scn=" + scn
                + " user=[" + user + "]"
                + " tx=" + (txId.isEmpty() ? "<none>" : txId));
    }

    private static void report(String what, boolean ok, String detail) {
        System.out.println((ok ? "  PASS  " : "  FAIL  ") + what + "  (" + detail + ")");
    }
}
