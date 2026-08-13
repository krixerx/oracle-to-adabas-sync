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
 */
public final class AggregateDef {

    /** A child collection: an MU or PE group in Adabas terms. */
    public record Child(String table, String orderColumn, List<String> payloadColumns) {
    }

    private final String name;
    private final String rootTable;
    private final String businessKeyColumn;
    private final List<String> rootColumns;
    private final List<Child> children;
    private final String rootSelectSql;
    private final String keyFromChildSql;

    private AggregateDef(String name, String rootTable, String businessKeyColumn,
                         List<String> rootColumns, List<Child> children,
                         String rootSelectSql, String keyFromChildSql) {
        this.name = name;
        this.rootTable = rootTable;
        this.businessKeyColumn = businessKeyColumn;
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
     * re-reading easy: Debezium reports a new address line as
     * {@code EMP_ID=7029}, but Adabas knows the record as
     * {@code PERSONNEL_ID='11100102'}. One lookup turns the surrogate key
     * back into the business key, and then the whole aggregate is re-read.
     */
    public String keyFromChildSql() {
        return keyFromChildSql;
    }

    public String childSelectSql(Child child) {
        return "SELECT " + String.join(", ", child.payloadColumns())
                + " FROM POCAPP." + child.table()
                + " WHERE EMP_ID = (SELECT EMP_ID FROM POCAPP.EMPLOYEE WHERE "
                + businessKeyColumn + " = ?)"
                + " ORDER BY " + child.orderColumn();
    }

    // ---------------------------------------------------------------------
    // The two this lab aggregates
    // ---------------------------------------------------------------------

    /** EMPLOYEES (Adabas file 11): parent + two MU groups + one PE group. */
    public static final AggregateDef EMPLOYEE = new AggregateDef(
            "employee",
            "EMPLOYEE",
            "PERSONNEL_ID",
            List.of("PERSONNEL_ID", "SOURCE_ISN", "FIRST_NAME", "MIDDLE_NAME", "LAST_NAME",
                    "BIRTH_DATE", "GENDER_CODE", "MARITAL_STATUS", "DEPT_CODE", "JOB_TITLE",
                    "CITY", "POSTAL_CODE", "COUNTRY_CODE"),
            List.of(
                    new Child("EMPLOYEE_ADDRESS_LINE", "LINE_NO", List.of("ADDRESS_LINE")),
                    new Child("EMPLOYEE_LANGUAGE", "SEQ_NO", List.of("LANGUAGE_CODE")),
                    new Child("EMPLOYEE_INCOME", "SEQ_NO", List.of("CURRENCY_CODE", "SALARY_AMOUNT"))),
            // BIRTH_DATE is emitted as YYYYMMDD here rather than left to Hop:
            // the change file is the mainframe-facing contract and Adabas
            // stores the date numerically, so the text form must be exact.
            "SELECT PERSONNEL_ID, SOURCE_ISN, FIRST_NAME, MIDDLE_NAME, LAST_NAME,"
                    + " TO_CHAR(BIRTH_DATE,'YYYYMMDD') AS BIRTH_DATE, GENDER_CODE,"
                    + " MARITAL_STATUS, DEPT_CODE, JOB_TITLE, CITY, POSTAL_CODE, COUNTRY_CODE"
                    + " FROM POCAPP.EMPLOYEE WHERE PERSONNEL_ID = ?",
            "SELECT PERSONNEL_ID FROM POCAPP.EMPLOYEE WHERE EMP_ID = ?");

    /** VEHICLES (Adabas file 12): flat, keyed by registration number. */
    public static final AggregateDef VEHICLE = new AggregateDef(
            "vehicle",
            "VEHICLE",
            "REG_NUM",
            List.of("REG_NUM", "SOURCE_ISN", "PERSONNEL_ID", "MAKE", "MODEL", "COLOR", "YEAR_BUILT"),
            List.of(),
            "SELECT v.REG_NUM, v.SOURCE_ISN, e.PERSONNEL_ID, v.MAKE, v.MODEL, v.COLOR,"
                    + " v.YEAR_BUILT"
                    + " FROM POCAPP.VEHICLE v LEFT JOIN POCAPP.EMPLOYEE e ON e.EMP_ID = v.EMP_ID"
                    + " WHERE v.REG_NUM = ?",
            null);

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
            "EMPLOYEE", new Owner(EMPLOYEE, null),
            "EMPLOYEE_ADDRESS_LINE", new Owner(EMPLOYEE, "EMP_ID"),
            "EMPLOYEE_LANGUAGE", new Owner(EMPLOYEE, "EMP_ID"),
            "EMPLOYEE_INCOME", new Owner(EMPLOYEE, "EMP_ID"),
            "VEHICLE", new Owner(VEHICLE, null));

    public static Optional<Owner> ownerOf(String table) {
        return Optional.ofNullable(BY_TABLE.get(table.toUpperCase()));
    }

    public static List<AggregateDef> all() {
        return List.of(EMPLOYEE, VEHICLE);
    }
}
