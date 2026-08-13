package com.example.o2a.capture;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Re-reads whole aggregates from Oracle (spec C3 stage 3, decision D4).
 *
 * <p>The simplification this class exists to exploit: <b>Debezium notifies,
 * Oracle supplies the payload.</b> Rather than reconstructing a record from
 * a stream of row deltas, we take the delta as nothing more than "aggregate X
 * changed" and then read X in full with ordinary SQL. Three things fall out
 * for free:
 * <ul>
 *   <li>MU/PE sets are naturally complete, so full-set replacement (D8) needs
 *       no delta bookkeeping;</li>
 *   <li>a change to a child row resolves to its parent's business key with one
 *       lookup, instead of needing the parent's state carried alongside;</li>
 *   <li>apply becomes idempotent by construction — the file carries desired
 *       state, not a diff, so replaying it twice is a no-op.</li>
 * </ul>
 *
 * <p>The cost is one SELECT per changed aggregate per batch, and a known
 * trade-off: we write the state as of the read, not as of the commit. If the
 * row changes again between commit and read, the later state wins and the
 * intermediate one is never sent. For a synchroniser converging on current
 * state that is correct; for an audit trail it would not be.
 */
public final class AggregateResolver implements AutoCloseable {

    private final Connection conn;

    public AggregateResolver(CaptureConfig cfg) throws SQLException {
        // The aggregate re-read must run against the PDB, where the tables
        // live - NOT the CDB root that Debezium mines from.
        String url = "jdbc:oracle:thin:@//" + cfg.get("database.hostname") + ":"
                + cfg.get("database.port", "1521") + "/"
                + cfg.get("aggregate.read.service", "FREEPDB1");
        this.conn = DriverManager.getConnection(url,
                cfg.get("aggregate.read.user", "pocapp"),
                cfg.get("aggregate.read.password", "pocapp"));
        this.conn.setReadOnly(true);
        this.conn.setAutoCommit(true);
    }

    /**
     * Turns a change on any table into the business key of the aggregate root
     * it belongs to.
     *
     * @param keyValue for a root table, the business key itself; for a child
     *                 table, the foreign key value (e.g. {@code EMP_ID})
     */
    public Optional<String> resolveRootKey(AggregateDef.Owner owner, String keyValue)
            throws SQLException {
        if (owner.isRoot()) {
            return Optional.ofNullable(keyValue);
        }
        try (PreparedStatement ps = conn.prepareStatement(owner.aggregate().keyFromChildSql())) {
            ps.setString(1, keyValue);
            try (ResultSet rs = ps.executeQuery()) {
                // Absent parent is normal, not an error: the whole aggregate
                // may have been deleted in the same transaction that removed
                // the child. The delete of the root carries the news.
                return rs.next() ? Optional.ofNullable(rs.getString(1)) : Optional.empty();
            }
        }
    }

    /**
     * Reads the aggregate in full.
     *
     * @return empty if the root no longer exists (it was deleted) — the caller
     *         then emits {@code op=D} from the change event's before-image
     */
    public Optional<Aggregate> read(AggregateDef def, String businessKey) throws SQLException {
        Map<String, String> root;
        try (PreparedStatement ps = conn.prepareStatement(def.rootSelectSql())) {
            ps.setString(1, businessKey);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    return Optional.empty();
                }
                root = readRow(rs);
            }
        }

        Map<String, List<Map<String, String>>> childSets = new LinkedHashMap<>();
        for (AggregateDef.Child child : def.children()) {
            List<Map<String, String>> rows = new ArrayList<>();
            try (PreparedStatement ps = conn.prepareStatement(def.childSelectSql(child))) {
                ps.setString(1, businessKey);
                try (ResultSet rs = ps.executeQuery()) {
                    while (rs.next()) {
                        rows.add(readRow(rs));
                    }
                }
            }
            // An empty list is meaningful, not missing data: it tells the
            // applier the MU/PE set is now empty (contract C4). Storing it
            // explicitly keeps "no rows" distinct from "not fetched".
            childSets.put(child.table(), rows);
        }
        return Optional.of(new Aggregate(def, businessKey, root, childSets));
    }

    private static Map<String, String> readRow(ResultSet rs) throws SQLException {
        ResultSetMetaData md = rs.getMetaData();
        Map<String, String> row = new LinkedHashMap<>();
        for (int i = 1; i <= md.getColumnCount(); i++) {
            row.put(md.getColumnLabel(i).toUpperCase(), rs.getString(i));
        }
        return row;
    }

    @Override
    public void close() throws SQLException {
        conn.close();
    }

    /** One aggregate's full current state. */
    public record Aggregate(AggregateDef def,
                            String businessKey,
                            Map<String, String> root,
                            Map<String, List<Map<String, String>>> children) {
    }
}
