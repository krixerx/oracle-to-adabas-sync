package com.example.o2a.capture;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

/**
 * Turns Debezium row events into change-file rows (spec C3 stages 1–4).
 *
 * <p>Pipeline: originator filter → transaction buffer → aggregate re-read →
 * change rows. Not thread-safe; the embedded engine calls it from one thread.
 */
public final class Assembler {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final AggregateResolver resolver;
    private final String originatorFilterUser;

    /** Aggregates touched since the last flush, in first-seen order. */
    private final Set<TouchedKey> touched = new LinkedHashSet<>();
    /** Roots deleted since the last flush; their state cannot be re-read. */
    private final Map<TouchedKey, Map<String, String>> deleted = new LinkedHashMap<>();

    private final Set<String> transactionsSeen = new LinkedHashSet<>();
    private String startScn;
    private String endScn;

    private long filteredEchoCount;
    private long unmappedTableCount;

    public Assembler(AggregateResolver resolver, String originatorFilterUser) {
        this.resolver = resolver;
        this.originatorFilterUser = originatorFilterUser;
    }

    /** @return true if the event contributed something to the pending batch */
    public boolean accept(String eventValue) throws Exception {
        if (eventValue == null) {
            return false; // tombstone
        }
        JsonNode node = MAPPER.readTree(eventValue);

        // Transaction metadata and schema-change events are not row changes.
        if (!node.path("status").isMissingNode() || node.path("op").isMissingNode()) {
            return false;
        }

        JsonNode source = node.path("source");
        String table = source.path("table").asText("");
        String user = source.path("user_name").asText("");
        String scn = source.path("scn").asText("");
        String txId = node.path("transaction").path("id").asText("");
        String op = node.path("op").asText("");

        // --- stage 1: originator filter (decision D6) --------------------
        // Drops changes this synchroniser itself applied, so a replicated
        // write never travels back. Stateless: no ledger, no timing window,
        // no chance of swallowing a genuine change. Spike S2 proved the
        // username distinguishes originators; S3 proved it survives to here.
        if (originatorFilterUser != null && originatorFilterUser.equalsIgnoreCase(user)) {
            filteredEchoCount++;
            return false;
        }

        Optional<AggregateDef.Owner> maybeOwner = AggregateDef.ownerOf(table);
        if (maybeOwner.isEmpty()) {
            unmappedTableCount++;
            return false;
        }
        AggregateDef.Owner owner = maybeOwner.get();
        AggregateDef def = owner.aggregate();

        if (!txId.isEmpty()) {
            transactionsSeen.add(txId);
        }
        if (startScn == null) {
            startScn = scn;
        }
        endScn = scn;

        // For a delete the row is gone, so the key must come from the
        // before-image; for everything else "after" is authoritative.
        boolean isDelete = "d".equals(op);
        JsonNode image = isDelete ? node.path("before") : node.path("after");
        if (image.isMissingNode() || image.isNull()) {
            return false;
        }

        String lookupColumn = owner.isRoot() ? def.businessKeyColumn() : owner.childKeyColumn();
        String lookupValue = text(image.path(lookupColumn));
        if (lookupValue == null) {
            return false;
        }

        if (isDelete && owner.isRoot()) {
            // The root itself went away: record it and stop. Re-reading is
            // pointless, and a later child event for the same key must not
            // resurrect it as an upsert.
            TouchedKey key = new TouchedKey(def.name(), lookupValue);
            touched.remove(key);
            deleted.put(key, toMap(image));
            return true;
        }

        Optional<String> rootKey = resolver.resolveRootKey(owner, lookupValue);
        if (rootKey.isEmpty()) {
            // Parent already gone - the root delete carries the news.
            return false;
        }
        TouchedKey key = new TouchedKey(def.name(), rootKey.get());
        if (!deleted.containsKey(key)) {
            touched.add(key);
        }
        return true;
    }

    public boolean hasPendingWork() {
        return !touched.isEmpty() || !deleted.isEmpty();
    }

    public int pendingTransactionCount() {
        return transactionsSeen.size();
    }

    public String startScn() {
        return startScn == null ? "" : startScn;
    }

    public String endScn() {
        return endScn == null ? "" : endScn;
    }

    public long filteredEchoCount() {
        return filteredEchoCount;
    }

    public long unmappedTableCount() {
        return unmappedTableCount;
    }

    /**
     * Stage 3+4: re-read every touched aggregate and produce the change rows.
     * Clears the pending set — the caller must persist what it gets back.
     */
    public List<BatchWriter.ChangeRow> drain() throws SQLException {
        List<BatchWriter.ChangeRow> rows = new ArrayList<>();
        int txSeq = 0;

        for (Map.Entry<TouchedKey, Map<String, String>> e : deleted.entrySet()) {
            AggregateDef def = defOf(e.getKey().aggregate());
            rows.add(deleteRow(def, e.getKey().businessKey(), ++txSeq));
        }

        for (TouchedKey key : touched) {
            AggregateDef def = defOf(key.aggregate());
            Optional<AggregateResolver.Aggregate> agg = resolver.read(def, key.businessKey());
            if (agg.isEmpty()) {
                // Deleted between capture and re-read. Emitting a delete is
                // the honest outcome: the desired end state is "absent".
                rows.add(deleteRow(def, key.businessKey(), ++txSeq));
                continue;
            }
            txSeq++;
            rows.addAll(upsertRows(agg.get(), txSeq));
        }

        touched.clear();
        deleted.clear();
        transactionsSeen.clear();
        startScn = null;
        endScn = null;
        return rows;
    }

    private static AggregateDef defOf(String name) {
        return AggregateDef.all().stream()
                .filter(d -> d.name().equals(name))
                .findFirst()
                .orElseThrow(() -> new IllegalStateException("unknown aggregate " + name));
    }

    /**
     * A delete carries the SAME columns as an upsert, with everything except
     * the key left empty.
     *
     * <p>Not cosmetic: the downstream mapping reads a fixed column list, so a
     * short row would either fail the pipeline or silently shift values into
     * the wrong fields. The contract says a delete's non-key columns are
     * meaningless, not absent.
     */
    private static BatchWriter.ChangeRow deleteRow(AggregateDef def, String key, int txSeq) {
        List<String> columns = parentColumns(def);
        Map<String, String> values = new LinkedHashMap<>();
        for (String col : columns) {
            values.put(col, "");
        }
        values.put("op", "D");
        values.put("tx_seq", Integer.toString(txSeq));
        values.put(def.businessKeyColumn().toLowerCase(), key);
        return new BatchWriter.ChangeRow(def.name(), columns, values);
    }

    private static List<String> parentColumns(AggregateDef def) {
        List<String> columns = new ArrayList<>(List.of("op", "tx_seq"));
        def.rootColumns().forEach(c -> columns.add(c.toLowerCase()));
        return columns;
    }

    /**
     * Every file this assembler can produce, with its header.
     *
     * <p>The batch writer uses this to emit a HEADER-ONLY file for shapes with
     * no rows, instead of omitting the file. Two reasons, both learned the
     * hard way:
     * <ul>
     *   <li>the mapping step's CSV reader fails outright on a missing file,
     *       and a new employee with no address lines is a perfectly ordinary
     *       case — so "no rows" must not mean "no file";</li>
     *   <li>an empty child file is <b>meaningful</b> under the contract: it
     *       says the MU/PE set is now empty. Omitting it would be
     *       indistinguishable from "unchanged".</li>
     * </ul>
     */
    public static Map<String, List<String>> allFileHeaders() {
        Map<String, List<String>> headers = new LinkedHashMap<>();
        for (AggregateDef def : AggregateDef.all()) {
            headers.put(def.name(), parentColumns(def));
            for (AggregateDef.Child child : def.children()) {
                List<String> columns = new ArrayList<>(List.of("parent_key", "occurrence_index"));
                child.payloadColumns().forEach(c -> columns.add(c.toLowerCase()));
                headers.put(fileNameOf(child), columns);
            }
        }
        return headers;
    }

    private static List<BatchWriter.ChangeRow> upsertRows(AggregateResolver.Aggregate agg,
                                                         int txSeq) {
        List<BatchWriter.ChangeRow> rows = new ArrayList<>();
        AggregateDef def = agg.def();

        List<String> parentColumns = parentColumns(def);
        Map<String, String> parentValues = new LinkedHashMap<>();
        parentValues.put("op", "U");
        parentValues.put("tx_seq", Integer.toString(txSeq));
        for (String col : def.rootColumns()) {
            parentValues.put(col.toLowerCase(), agg.root().get(col.toUpperCase()));
        }
        rows.add(new BatchWriter.ChangeRow(def.name(), parentColumns, parentValues));

        for (AggregateDef.Child child : def.children()) {
            List<Map<String, String>> childRows = agg.children().get(child.table());
            // NOTE: no rows means the set is now EMPTY, and that is exactly
            // what the applier must see. The parent row alone is not enough
            // to convey "all occurrences removed" - hence the contract rule
            // that child sets are always complete for a parent with op=U.
            if (childRows == null) {
                continue;
            }
            List<String> columns = new ArrayList<>(List.of("parent_key", "occurrence_index"));
            child.payloadColumns().forEach(c -> columns.add(c.toLowerCase()));
            int occurrence = 0;
            for (Map<String, String> row : childRows) {
                occurrence++;
                Map<String, String> values = new LinkedHashMap<>();
                values.put("parent_key", agg.businessKey());
                // Renumbered 1..n contiguously here, NOT copied from the
                // Oracle order column: Adabas occurrences must be dense, and
                // Oracle's LINE_NO/SEQ_NO can have gaps after deletes.
                values.put("occurrence_index", Integer.toString(occurrence));
                for (String col : child.payloadColumns()) {
                    values.put(col.toLowerCase(), row.get(col.toUpperCase()));
                }
                rows.add(new BatchWriter.ChangeRow(fileNameOf(child), columns, values));
            }
        }
        return rows;
    }

    private static String fileNameOf(AggregateDef.Child child) {
        return child.table().toLowerCase();
    }

    private static Map<String, String> toMap(JsonNode node) {
        Map<String, String> map = new LinkedHashMap<>();
        node.fieldNames().forEachRemaining(f -> map.put(f.toUpperCase(), text(node.path(f))));
        return map;
    }

    private static String text(JsonNode node) {
        if (node == null || node.isMissingNode() || node.isNull()) {
            return null;
        }
        // Oracle NUMBER arrives as a JSON number; asText() on a double would
        // render EMP_ID 7029 as "7029.0" and no lookup would ever match.
        if (node.isNumber() && node.asText().endsWith(".0")) {
            return node.asText().substring(0, node.asText().length() - 2);
        }
        return node.asText();
    }

    /** Identity of a pending aggregate: which definition, which business key. */
    private record TouchedKey(String aggregate, String businessKey) {
    }
}
