package com.example.o2a.capture;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * Writes one batch directory per flush (spec C4).
 *
 * <p>Files are the queue (decision D2). Two rules make that a real queue
 * rather than a hopeful one:
 * <ol>
 *   <li>{@code _COMPLETE} is written <b>last</b>. It is the commit point of
 *       the file protocol — a consumer ignores any directory without it, so a
 *       half-written batch can never be read.</li>
 *   <li>The producer never deletes a batch. The consumer acknowledges by
 *       renaming the directory into {@code applied/} or {@code rejected/},
 *       which is atomic on one filesystem.</li>
 * </ol>
 *
 * <p>Format follows {@code FLAT_FILE_CONTRACT.md} deliberately: BOM-less
 * UTF-8, RFC 4180 quoting, empty string = NULL, one file per target shape.
 * The Natural team then works with one convention in both directions.
 */
public final class BatchWriter {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Pattern BATCH_DIR = Pattern.compile("batch-(\\d{6})");

    /** Written last; its presence means the batch is readable. */
    public static final String COMPLETE_MARKER = "_COMPLETE";

    private final Path outbox;
    private final Map<String, List<String>> fileHeaders;
    private long nextBatch;

    public BatchWriter(Path outbox, Map<String, List<String>> fileHeaders) throws IOException {
        this.outbox = outbox;
        this.fileHeaders = fileHeaders;
        Files.createDirectories(outbox);
        this.nextBatch = highestExistingBatch() + 1;
    }

    /**
     * Batch numbers must keep increasing across restarts — the applier's
     * ledger stores the last one applied and refuses to go backwards, so a
     * counter that restarted at 1 would make every batch look already-done.
     * Scans applied/ and rejected/ too, since acknowledged batches move there.
     */
    private long highestExistingBatch() throws IOException {
        long max = 0;
        for (Path dir : List.of(outbox, outbox.resolveSibling("applied"),
                outbox.resolveSibling("rejected"))) {
            if (!Files.isDirectory(dir)) {
                continue;
            }
            try (Stream<Path> entries = Files.list(dir)) {
                max = Math.max(max, entries
                        .map(p -> p.getFileName().toString())
                        .map(BATCH_DIR::matcher)
                        .filter(java.util.regex.Matcher::matches)
                        .mapToLong(m -> Long.parseLong(m.group(1)))
                        .max().orElse(0));
            }
        }
        return max;
    }

    public long peekNextBatchNumber() {
        return nextBatch;
    }

    /**
     * Writes one batch. Returns the directory, or empty when there is
     * nothing to write (no empty batches — they would only add churn for the
     * applier to skip).
     */
    public java.util.Optional<Path> write(List<ChangeRow> rows,
                                          int transactionCount,
                                          String startScn,
                                          String endScn) throws IOException {
        if (rows.isEmpty()) {
            return java.util.Optional.empty();
        }
        long batch = nextBatch++;
        Path dir = outbox.resolve(String.format("batch-%06d", batch));
        Files.createDirectories(dir);

        Map<String, List<ChangeRow>> byFile = new LinkedHashMap<>();
        for (ChangeRow row : rows) {
            byFile.computeIfAbsent(row.fileName(), k -> new ArrayList<>()).add(row);
        }

        Map<String, Integer> counts = new LinkedHashMap<>();
        // EVERY known file is written, header-only when it has no rows.
        // A missing file breaks the mapping step's CSV reader, and "no rows"
        // is a perfectly ordinary case (an employee with no address lines).
        // It is also semantically required: an empty child file means the
        // MU/PE set is now empty, which is not the same as "unchanged".
        for (Map.Entry<String, List<String>> header : fileHeaders.entrySet()) {
            List<ChangeRow> fileRows = byFile.getOrDefault(header.getKey(), List.of());
            writeCsv(dir.resolve(header.getKey() + ".csv"), header.getValue(), fileRows);
            counts.put(header.getKey(), fileRows.size());
        }

        writeManifest(dir, batch, transactionCount, startScn, endScn, counts);

        // LAST. Everything above must be on disk and closed before this exists.
        Files.writeString(dir.resolve(COMPLETE_MARKER), "", StandardCharsets.UTF_8);
        return java.util.Optional.of(dir);
    }

    private void writeManifest(Path dir, long batch, int transactionCount,
                               String startScn, String endScn,
                               Map<String, Integer> counts) throws IOException {
        ObjectNode manifest = MAPPER.createObjectNode();
        manifest.put("batch", batch);
        manifest.put("created_utc", java.time.Instant.now().toString());
        manifest.put("start_scn", startScn);
        manifest.put("end_scn", endScn);
        manifest.put("transactions", transactionCount);
        ObjectNode rowCounts = manifest.putObject("row_counts");
        counts.forEach(rowCounts::put);
        Files.writeString(dir.resolve("manifest.json"),
                MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(manifest),
                StandardCharsets.UTF_8);
    }

    private void writeCsv(Path file, List<String> columns, List<ChangeRow> rows)
            throws IOException {
        // Explicit UTF-8 with no BOM: a BOM would land in the first header
        // cell and the mainframe side would silently look for a column that
        // does not match. Same rule as the the migration lab contract.
        try (BufferedWriter w = Files.newBufferedWriter(file, StandardCharsets.UTF_8)) {
            w.write(String.join(",", columns));
            w.write("\n");
            for (ChangeRow row : rows) {
                List<String> values = new ArrayList<>(columns.size());
                for (String col : columns) {
                    values.add(quote(row.values().get(col)));
                }
                w.write(String.join(",", values));
                w.write("\n");
            }
        }
    }

    /** RFC 4180: quote only when needed; null becomes an empty field (= NULL). */
    private static String quote(String value) {
        if (value == null) {
            return "";
        }
        if (value.indexOf(',') < 0 && value.indexOf('"') < 0
                && value.indexOf('\n') < 0 && value.indexOf('\r') < 0) {
            return value;
        }
        return '"' + value.replace("\"", "\"\"") + '"';
    }

    /** One line of one change file. */
    public record ChangeRow(String fileName, List<String> columns, Map<String, String> values) {
    }
}
