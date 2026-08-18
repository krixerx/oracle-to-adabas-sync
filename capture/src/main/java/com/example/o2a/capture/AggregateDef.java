package com.example.o2a.capture;

import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * Which Oracle tables form one Adabas record, and how to re-read the whole
 * thing (spec C3 stage 3, decision D4).
 *
 * <p>Hand-written for this lab, deliberately. The spec sketches a YAML shape
 * so this can become configuration later, but the second-opinion advice from
 * the migration lab stands: do not build a generic mapping-spec compiler before a third
 * aggregate has proved the pattern. Two aggregates is not a pattern.
 *
 * <h2>What is deliberately NOT carried back to Adabas</h2>
 * Columns the migration <i>derived</i> have no field in the source and are
 * absent from {@link #rootColumns()}: {@code POWERTRAIN_CODE} and
 * {@code POWERTRAIN_SOURCE} (computed from the VIN or the fuel text), and
 * {@code VEHICLE_ID} on a fine (Adabas records the plate the camera read, never
 * the vehicle). A change to one of them still triggers a re-read, and the
 * applier then finds Adabas already in the desired state and reports
 * NOOP-IDENTICAL — which is the correct outcome, not a missed change.
 *
 * <p>⚠️ This is the opposite of the MU/PE rule, and the difference is worth
 * keeping straight: an unmapped field inside a periodic group keeps an
 * occurrence alive and must still be RESET, whereas an Oracle-only column has
 * no Adabas counterpart at all and is simply dropped.
 */
public final class AggregateDef {

    /**
     * A child collection: an MU or PE group in Adabas terms.
     *
     * @param selectList SQL expressions for {@code payloadColumns}, in the same
     *                   order and aliased to the same names. Dates and amounts
     *                   are formatted here rather than left to Hop, for the
     *                   same reason the root does it — the change file is the
     *                   mainframe-facing contract, and Adabas stores a date
     *                   numerically.
     */
    public record Child(String table, String orderColumn, List<String> payloadColumns,
                        String selectList) {
    }

    private final String name;
    private final String rootTable;
    private final String businessKeyColumn;
    private final String parentKeyColumn;
    private final List<String> rootColumns;
    private final List<Child> children;
    private final String rootSelectSql;
    private final String keyFromChildSql;

    private AggregateDef(String name, String rootTable, String businessKeyColumn,
                         String parentKeyColumn, List<String> rootColumns, List<Child> children,
                         String rootSelectSql, String keyFromChildSql) {
        this.name = name;
        this.rootTable = rootTable;
        this.businessKeyColumn = businessKeyColumn;
        this.parentKeyColumn = parentKeyColumn;
        this.rootColumns = rootColumns;
        this.children = children;
        this.rootSelectSql = rootSelectSql;
        this.keyFromChildSql = keyFromChildSql;
    }

    public String name() {
        return name;
    }

    public String rootTable() {
        return rootTable;
    }

    public String businessKeyColumn() {
        return businessKeyColumn;
    }

    /** The surrogate key children hang off — {@code FINE_ID}, {@code VEHICLE_ID}. */
    public String parentKeyColumn() {
        return parentKeyColumn;
    }

    public List<String> rootColumns() {
        return rootColumns;
    }

    public List<Child> children() {
        return children;
    }

    /** Re-reads the aggregate root in full, by business key. */
    public String rootSelectSql() {
        return rootSelectSql;
    }

    /**
     * Resolves the business key from a change to a CHILD row.
     *
     * <p>This is the case that makes reconstruction-from-deltas painful and
     * re-reading easy: Debezium reports a new offence as {@code FINE_ID=812},
     * but Adabas knows the record as {@code FINE-NO='F000000005'}. One lookup
     * turns the surrogate key back into the business key, and then the whole
     * aggregate is re-read.
     */
    public String keyFromChildSql() {
        return keyFromChildSql;
    }

    public String childSelectSql(Child child) {
        return "SELECT " + child.selectList()
                + " FROM POCAPP." + child.table()
                + " WHERE " + parentKeyColumn + " = (SELECT " + parentKeyColumn
                + " FROM POCAPP." + rootTable + " WHERE " + businessKeyColumn + " = ?)"
                + " ORDER BY " + child.orderColumn();
    }

    // ---------------------------------------------------------------------
    // The two aggregates this lab syncs
    // ---------------------------------------------------------------------

    /**
     * TRAFFIC FINES (Adabas file 20 TRAFFINE): one root, one MU (offence
     * codes seen in a single stop) and one PE (part payments).
     *
     * <p>Both the resolved description and the code it came from are carried —
     * {@code STATUS}/{@code STATUS_CODE}, {@code METHOD}/{@code METHOD_CODE},
     * {@code OFFENCE_DESC}/{@code OFFENCE_CODE}. Adabas stores only the code,
     * so the code alone would be enough to write. Sending both lets the Hop
     * pipeline run the reverse CODE_LOOKUP and <b>check its answer against the
     * code already in Oracle</b>: a disagreement means the description and the
     * code have drifted apart, and that is a data fault worth failing on rather
     * than quietly overwriting the mainframe with.
     */
    public static final AggregateDef TRAFFIC_FINE = new AggregateDef(
            "traffic_fine",
            "TRAFFIC_FINE",
            "FINE_NO",
            "FINE_ID",
            List.of("FINE_NO", "SOURCE_ISN", "PLATE_NO", "OFFENCE_DATE", "LOCATION",
                    "AMOUNT", "STATUS_CODE", "STATUS", "OFFENDER_NATIONAL_ID"),
            List.of(
                    new Child("TRAFFIC_FINE_OFFENCE", "SEQ_NO",
                            List.of("OFFENCE_CODE", "OFFENCE_DESC"),
                            "OFFENCE_CODE, OFFENCE_DESC"),
                    new Child("TRAFFIC_FINE_PAYMENT", "SEQ_NO",
                            List.of("PAID_DATE", "PAID_AMOUNT", "METHOD_CODE", "METHOD"),
                            "TO_CHAR(PAID_DATE,'YYYYMMDD') AS PAID_DATE,"
                                    + " TO_CHAR(PAID_AMOUNT,'FM99999990.00') AS PAID_AMOUNT,"
                                    + " METHOD_CODE, METHOD")),
            // OFFENCE_DATE and AMOUNT are rendered here, not in Hop: Adabas
            // holds the date as numeric YYYYMMDD and the amount as packed P7.2,
            // so the text form has to be exact and unambiguous. FM strips the
            // padding TO_CHAR would otherwise add; the trailing .00 is kept so
            // the field never arrives as a bare integer.
            "SELECT FINE_NO, SOURCE_ISN, PLATE_NO,"
                    + " TO_CHAR(OFFENCE_DATE,'YYYYMMDD') AS OFFENCE_DATE, LOCATION,"
                    + " TO_CHAR(AMOUNT,'FM99999990.00') AS AMOUNT, STATUS_CODE, STATUS,"
                    + " OFFENDER_NATIONAL_ID"
                    + " FROM POCAPP.TRAFFIC_FINE WHERE FINE_NO = ?",
            "SELECT FINE_NO FROM POCAPP.TRAFFIC_FINE WHERE FINE_ID = ?");

    /**
     * VEHICLES (Adabas file 12): one root and its registration plates.
     *
     * <p>⚠️ The shapes do not correspond one to one, and this is the sharpest
     * difference from the fine aggregate. Adabas file 12 holds <b>one record
     * per plate</b> — the source has nowhere to record a second registration,
     * so a second plate was registered again under the same VIN with a
     * character appended. Oracle turned that into one vehicle plus up to three
     * plate rows. Writing back therefore means reconciling a SET OF RECORDS,
     * not occupancy inside one record, and every one of those records repeats
     * the vehicle's own attributes. {@code VEHICLE_PLATE.SOURCE_ISN} is what
     * makes it tractable: each plate row still carries the ISN of the Adabas
     * record it came from.
     *
     * <p>{@code SOURCE_VEHICLE_TYPE} (the legacy code as found) and
     * {@code VEHICLE_TYPE_CODE} (the standard code it maps to) are both sent
     * for the same reason the fine sends both status forms — but here the
     * reverse mapping is <b>lossy</b>: SEDAN, ESTATE and HATCH all map to PC,
     * so PC cannot be turned back into the original. The lineage column is
     * therefore authoritative and the reverse map is only a fallback. See the
     * Hop pipeline.
     */
    public static final AggregateDef VEHICLE = new AggregateDef(
            "vehicle",
            "VEHICLE",
            "VIN",
            "VEHICLE_ID",
            List.of("VIN", "SOURCE_ISN", "OWNER_NATIONAL_ID", "MAKE", "MODEL", "COLOR",
                    "YEAR_BUILT", "SOURCE_VEHICLE_TYPE", "VEHICLE_TYPE_CODE",
                    "SOURCE_FUEL_DESC"),
            List.of(new Child("VEHICLE_PLATE", "PLATE_SEQ",
                    List.of("PLATE_NO", "SOURCE_ISN", "EXPIRY_DATE"),
                    // 00000000 rather than empty for a current plate: Adabas
                    // already uses 0 to mean "not expired", and an all-numeric
                    // field lets the applier read it as N8 with no conversion.
                    "PLATE_NO, SOURCE_ISN,"
                            + " NVL(TO_CHAR(EXPIRY_DATE,'YYYYMMDD'),'00000000')"
                            + " AS EXPIRY_DATE")),
            "SELECT VIN, SOURCE_ISN, OWNER_NATIONAL_ID, MAKE, MODEL, COLOR,"
                    + " TO_CHAR(YEAR_BUILT) AS YEAR_BUILT, SOURCE_VEHICLE_TYPE,"
                    + " VEHICLE_TYPE_CODE, SOURCE_FUEL_DESC"
                    + " FROM POCAPP.VEHICLE WHERE VIN = ?",
            "SELECT VIN FROM POCAPP.VEHICLE WHERE VEHICLE_ID = ?");

    /**
     * Maps a changed table to the aggregate that owns it, and to the column
     * whose value identifies the affected root.
     *
     * <p>{@code null} lookup column means the changed table IS the root, so
     * the business key is already present in the event.
     */
    public record Owner(AggregateDef aggregate, String childKeyColumn) {
        public boolean isRoot() {
            return childKeyColumn == null;
        }
    }

    private static final Map<String, Owner> BY_TABLE = Map.of(
            "TRAFFIC_FINE", new Owner(TRAFFIC_FINE, null),
            "TRAFFIC_FINE_OFFENCE", new Owner(TRAFFIC_FINE, "FINE_ID"),
            "TRAFFIC_FINE_PAYMENT", new Owner(TRAFFIC_FINE, "FINE_ID"),
            "VEHICLE", new Owner(VEHICLE, null),
            "VEHICLE_PLATE", new Owner(VEHICLE, "VEHICLE_ID"));

    public static Optional<Owner> ownerOf(String table) {
        return Optional.ofNullable(BY_TABLE.get(table.toUpperCase()));
    }

    /**
     * Every aggregate this capture engine ACTIVELY syncs.
     *
     * <p>⚠️ An aggregate listed here is captured, so something downstream must be
     * able to map and apply it: a Hop pipeline, an entry in {@code sync-apply.hwf},
     * a Natural applier, and the matching work file in {@code run-apply.sh}.
     * Captured with nowhere to be applied is not half-finished — it is
     * <b>silently dropped at the mapping stage</b>, which looks exactly like a
     * working sync until someone checks Adabas. {@code table.include.list} is
     * the other half of the switch and must be changed with this list.
     */
    public static List<AggregateDef> all() {
        return List.of(TRAFFIC_FINE, VEHICLE);
    }
}
