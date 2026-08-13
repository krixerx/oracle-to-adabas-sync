-- Oracle to Adabas sync — Oracle change-capture prerequisites (spec C1).
--
-- Runs as SYSDBA against the CDB root (gvenzl/oracle-free executes
-- /container-entrypoint-initdb.d/*.sql with `sqlplus -s / as sysdba`).
-- Fully idempotent, so it is also safe to apply by hand to an existing
-- lab volume — which is how it reaches a database that was created
-- before this lab existed. scripts/setup-cdc.ps1 does exactly that.
--
-- NOT handled here: ARCHIVELOG mode. It requires the database in MOUNT
-- state, so it is a deliberate one-time operator step in
-- scripts/enable-archivelog.sh rather than a silent init hook.

SET SERVEROUTPUT ON
SET FEEDBACK OFF

-- ===================================================================
-- 1. Database-level supplemental logging (CDB root)
--    minimal + primary key: makes SQL_REDO carry real column
--    predicates instead of ROWIDs. Proven by spike S2.
-- ===================================================================
DECLARE
  PROCEDURE try(p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    DBMS_OUTPUT.PUT_LINE('  applied : ' || p_sql);
  EXCEPTION
    WHEN OTHERS THEN
      -- ORA-32588: supplemental logging attribute already exists
      IF SQLCODE IN (-32588, -32589) THEN
        DBMS_OUTPUT.PUT_LINE('  already : ' || p_sql);
      ELSE
        RAISE;
      END IF;
  END;
BEGIN
  try('ALTER DATABASE ADD SUPPLEMENTAL LOG DATA');
  try('ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS');
END;
/

-- ===================================================================
-- 2. Capture user — common user, must exist in every container
-- ===================================================================
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = 'C##DBZUSER';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER c##dbzuser IDENTIFIED BY dbz ' ||
                      'DEFAULT TABLESPACE users QUOTA UNLIMITED ON users ' ||
                      'CONTAINER=ALL';
    DBMS_OUTPUT.PUT_LINE('  created : C##DBZUSER');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  already : C##DBZUSER');
  END IF;
END;
/

-- Grants per the Debezium Oracle connector (LogMiner adapter) requirements.
-- CONTAINER=ALL because mining happens from the CDB root while the tables
-- live in FREEPDB1.
GRANT CREATE SESSION                TO c##dbzuser CONTAINER=ALL;
GRANT SET CONTAINER                 TO c##dbzuser CONTAINER=ALL;
-- CREATE TABLE is genuinely required, not defensive over-granting: the
-- connector maintains a LOG_MINING_FLUSH table in its own schema and writes
-- to it to force an LGWR flush, so the redo it is about to mine is on disk.
-- Without it the connector starts, reads the schema, then dies with
-- "Failed to create flush table" / ORA-01031.
GRANT CREATE TABLE                  TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ANY TABLE              TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ANY TRANSACTION        TO c##dbzuser CONTAINER=ALL;
GRANT SELECT_CATALOG_ROLE           TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE_CATALOG_ROLE          TO c##dbzuser CONTAINER=ALL;
GRANT LOGMINING                     TO c##dbzuser CONTAINER=ALL;
GRANT FLASHBACK ANY TABLE           TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE ON DBMS_LOGMNR        TO c##dbzuser CONTAINER=ALL;
GRANT EXECUTE ON DBMS_LOGMNR_D      TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$DATABASE            TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOG                 TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOG_HISTORY         TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGFILE             TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$ARCHIVED_LOG        TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$ARCHIVE_DEST_STATUS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGMNR_CONTENTS     TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGMNR_LOGS         TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGMNR_PARAMETERS   TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$TRANSACTION         TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$MYSTAT              TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$STATNAME            TO c##dbzuser CONTAINER=ALL;

-- ===================================================================
-- 3. Application-side users and per-table supplemental logging (PDB)
-- ===================================================================
ALTER SESSION SET CONTAINER = FREEPDB1;

-- SYNCAPP is the apply-back user for the future Adabas -> Oracle leg.
-- It exists now because it is the ORIGINATOR FILTER TARGET (spec §5.1):
-- capture drops every change whose USERNAME is SYNCAPP, so replicated
-- changes never loop back. Spike S2 proved USERNAME distinguishes it.
DECLARE
  n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = 'SYNCAPP';
  IF n = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER syncapp IDENTIFIED BY syncapp ' ||
                      'DEFAULT TABLESPACE users QUOTA UNLIMITED ON users';
    DBMS_OUTPUT.PUT_LINE('  created : SYNCAPP');
  ELSE
    DBMS_OUTPUT.PUT_LINE('  already : SYNCAPP');
  END IF;
END;
/

GRANT CREATE SESSION TO syncapp;

-- The capture user needs a tablespace quota IN THE PDB for its flush table.
-- The QUOTA clause on CREATE USER ... CONTAINER=ALL does not propagate a
-- usable quota into each container, so grant it here explicitly - otherwise
-- CREATE TABLE succeeds as a privilege and then fails with ORA-01950
-- (no privileges on tablespace) at the moment the table is created.
ALTER USER c##dbzuser QUOTA UNLIMITED ON users;

DECLARE
  TYPE t_tabs IS TABLE OF VARCHAR2(40);
  v_tabs t_tabs := t_tabs('EMPLOYEE', 'EMPLOYEE_ADDRESS_LINE',
                          'EMPLOYEE_LANGUAGE', 'EMPLOYEE_INCOME', 'VEHICLE');
BEGIN
  FOR i IN 1 .. v_tabs.COUNT LOOP
    -- SYNCAPP must be able to write every synced table (apply-back leg)
    BEGIN
      EXECUTE IMMEDIATE 'GRANT SELECT, INSERT, UPDATE, DELETE ON pocapp.' ||
                        v_tabs(i) || ' TO syncapp';
    EXCEPTION WHEN OTHERS THEN
      DBMS_OUTPUT.PUT_LINE('  grant skipped for ' || v_tabs(i) || ': ' || SQLERRM);
    END;

    -- ALL COLUMNS supplemental logging puts the full BEFORE-IMAGE in the
    -- redo WHERE clause, which is what makes conflict detection (§5.4)
    -- essentially free. Spike S2 confirmed this.
    -- COST: raises redo volume on every update. Negligible in the lab; a
    -- real capacity conversation at production scale. PRIMARY KEY alone
    -- gives the key predicate but NO before-image.
    BEGIN
      EXECUTE IMMEDIATE 'ALTER TABLE pocapp.' || v_tabs(i) ||
                        ' ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS';
      DBMS_OUTPUT.PUT_LINE('  suppl ALL applied : ' || v_tabs(i));
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLCODE IN (-32588, -32589) THEN
          DBMS_OUTPUT.PUT_LINE('  suppl ALL already : ' || v_tabs(i));
        ELSE
          RAISE;
        END IF;
    END;
  END LOOP;
END;
/

EXIT;
