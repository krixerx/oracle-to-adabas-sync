package com.example.o2a.capture;

import io.debezium.engine.ChangeEvent;
import io.debezium.engine.DebeziumEngine;
import io.debezium.engine.format.Json;

import java.nio.file.Path;
import java.util.List;
import java.util.Optional;
import java.util.Properties;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * The Oracle capture service (spec C2–C4).
 *
 * <p>Runs the Debezium embedded engine, feeds every event through the
 * {@link Assembler}, and flushes a batch directory on a timer. One process,
 * no broker, plain files out.
 *
 * <p>Usage: {@code java -jar oracle-capture.jar <config.properties> [seconds]}
 * — with no duration it runs until interrupted.
 */
public final class CaptureMain {

    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            System.err.println("usage: CaptureMain <config.properties> [run-seconds]");
            System.exit(2);
        }
        long runSeconds = args.length > 1 ? Long.parseLong(args[1]) : -1;

        CaptureConfig cfg = CaptureConfig.load(Path.of(args[0]));
        Properties props = cfg.toDebeziumProperties();

        Path outbox = Path.of(cfg.get("batch.outbox.dir", "./sync/outbox"));
        long flushMs = cfg.getInt("batch.flush.interval.ms", 5000);
        String filterUser = cfg.get("originator.filter.user", "SYNCAPP");

        System.out.println("=== Oracle to Adabas sync - Oracle capture ===");
        System.out.println("  source     : " + props.getProperty("database.hostname")
                + "/" + props.getProperty("database.dbname")
                + " pdb=" + props.getProperty("database.pdb.name"));
        System.out.println("  outbox     : " + outbox.toAbsolutePath());
        System.out.println("  flush      : every " + flushMs + " ms");
        System.out.println("  filtering  : changes made by " + filterUser + " (loop prevention)");

        try (AggregateResolver resolver = new AggregateResolver(cfg)) {
            Assembler assembler = new Assembler(resolver, filterUser);
            BatchWriter writer = new BatchWriter(outbox, Assembler.allFileHeaders());
            System.out.println("  next batch : "
                    + String.format("batch-%06d", writer.peekNextBatchNumber()));

            CountDownLatch stopped = new CountDownLatch(1);
            Object lock = new Object();

            DebeziumEngine<ChangeEvent<String, String>> engine =
                    DebeziumEngine.create(Json.class)
                            .using(props)
                            .notifying(record -> {
                                try {
                                    // The engine calls this on one thread, but the
                                    // flush timer runs on another and drains the
                                    // same assembler - so both sides synchronize.
                                    synchronized (lock) {
                                        assembler.accept(record.value());
                                    }
                                } catch (Exception e) {
                                    System.err.println("!! event rejected: " + e);
                                    e.printStackTrace(System.err);
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

            ExecutorService engineExec = Executors.newSingleThreadExecutor();
            engineExec.execute(engine);

            ExecutorService flusher = Executors.newSingleThreadScheduledExecutor();
            ((java.util.concurrent.ScheduledExecutorService) flusher).scheduleWithFixedDelay(() -> {
                try {
                    flush(assembler, writer, lock);
                } catch (Exception e) {
                    // Never let a flush failure kill the timer: the events are
                    // still buffered and the offset has not advanced past them,
                    // so the next tick can retry.
                    System.err.println("!! flush failed: " + e);
                    e.printStackTrace(System.err);
                }
            }, flushMs, flushMs, TimeUnit.MILLISECONDS);

            Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                System.out.println("--- shutdown requested ---");
                try {
                    engine.close();
                } catch (Exception ignored) {
                    // best effort
                }
            }));

            if (runSeconds > 0) {
                stopped.await(runSeconds, TimeUnit.SECONDS);
            } else {
                stopped.await();
            }

            // Final flush so a clean stop does not strand buffered changes.
            flusher.shutdown();
            flusher.awaitTermination(30, TimeUnit.SECONDS);
            flush(assembler, writer, lock);

            try {
                engine.close();
            } catch (Exception ignored) {
                // already closed
            }
            engineExec.shutdownNow();
            engineExec.awaitTermination(30, TimeUnit.SECONDS);

            System.out.println("--- stopped. echoes filtered: "
                    + assembler.filteredEchoCount()
                    + ", events on unmapped tables: " + assembler.unmappedTableCount());
        }
    }

    private static void flush(Assembler assembler, BatchWriter writer, Object lock)
            throws Exception {
        List<BatchWriter.ChangeRow> rows;
        int transactions;
        String startScn;
        String endScn;
        synchronized (lock) {
            if (!assembler.hasPendingWork()) {
                return;
            }
            transactions = assembler.pendingTransactionCount();
            startScn = assembler.startScn();
            endScn = assembler.endScn();
            rows = assembler.drain();
        }
        Optional<Path> dir = writer.write(rows, transactions, startScn, endScn);
        dir.ifPresent(p -> System.out.println("  wrote " + p.getFileName()
                + "  rows=" + rows.size() + " transactions=" + transactions
                + " scn=" + startScn + ".." + endScn));
    }
}
