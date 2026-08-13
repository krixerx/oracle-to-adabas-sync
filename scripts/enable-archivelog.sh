#!/bin/sh
# Puts the lab Oracle into ARCHIVELOG mode and sizes the Fast Recovery
# Area. Runs INSIDE the o2a-oracle container. One-time operator step:
# ARCHIVELOG needs the database in MOUNT state, so it deliberately is NOT
# an init hook (spec C1 / gating spike S1).
#
# Safe to re-run: if the database is already in ARCHIVELOG mode it only
# re-asserts the FRA settings and exits.
#
# TWO THINGS THAT BITE HERE:
#  1. Use a LOCAL (bequeath) connection - `sqlplus / as sysdba` with
#     ORACLE_SID set - never `@//localhost:1521/FREE`. SHUTDOWN IMMEDIATE
#     deregisters the service from the listener, so a network connection
#     cannot issue the STARTUP that follows: ORA-12514, database left down.
#  2. The container survives all this because gvenzl's entrypoint runs
#     `tail -f` on the alert log as PID 1's foreground process, so
#     stopping the DATABASE does not stop the CONTAINER.
set -e

FRA_DIR=${FRA_DIR:-/opt/oracle/oradata/FRA}
FRA_SIZE=${FRA_SIZE:-8G}
ARCH_DIR=${ARCH_DIR:-/opt/oracle/oradata/ARCH}
ORACLE_SID=${ORACLE_SID:-FREE}
export ORACLE_SID

mkdir -p "$FRA_DIR" "$ARCH_DIR"

mode=$(sqlplus -s / as sysdba <<'EOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT log_mode FROM v$database;
EXIT;
EOF
)
mode=$(echo "$mode" | tr -d ' \r\n')
echo "current log_mode = $mode"

echo "--- sizing the FRA ($FRA_DIR, $FRA_SIZE) ---"
sqlplus -s / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF
ALTER SYSTEM SET db_recovery_file_dest_size = $FRA_SIZE SCOPE=BOTH;
ALTER SYSTEM SET db_recovery_file_dest = '$FRA_DIR' SCOPE=BOTH;
EXIT;
EOF

# ---------------------------------------------------------------------
# Archive logs go to a PLAIN DIRECTORY, deliberately NOT to the FRA.
#
# gvenzl/oracle-free:23-slim ships WITHOUT rman (only sqlplus). Nothing
# can then update the controlfile records for deleted archive logs, so
# FRA-managed logs would keep counting against db_recovery_file_dest_size
# even after the files were removed - and at 100% Oracle stops archiving
# and the database HANGS (ORA-19809) with the disk still half empty.
# An explicit destination sidesteps FRA space accounting entirely, and
# purge-archivelogs.sh can then simply delete by file age.
#
# PRODUCTION DIVERGENCE (state it, do not hide it): a full Oracle install
# has rman, and the standard answer there is FRA + an RMAN archivelog
# deletion policy. This lab uses a plain destination only because rman is
# absent from the slim image.
# ---------------------------------------------------------------------
echo "--- pointing archiving at $ARCH_DIR (outside the FRA) ---"
sqlplus -s / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF
ALTER SYSTEM SET log_archive_dest_1 = 'LOCATION=$ARCH_DIR' SCOPE=BOTH;
EXIT;
EOF

if [ "$mode" = "ARCHIVELOG" ]; then
  echo "--- already in ARCHIVELOG mode, nothing further to do ---"
else
  echo "--- switching to ARCHIVELOG (shutdown / mount / open) ---"
  sqlplus -s / as sysdba <<'EOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET FEEDBACK OFF
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
-- a PDB does not follow the CDB open after a manual cycle; SAVE STATE
-- makes it open automatically on every future startup
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER PLUGGABLE DATABASE FREEPDB1 SAVE STATE;
EXIT;
EOF
fi

echo "--- resulting state ---"
sqlplus -s / as sysdba <<'EOF'
SET LINESIZE 200 PAGESIZE 50 FEEDBACK OFF
SELECT log_mode, open_mode FROM v$database;
SELECT name, open_mode FROM v$pdbs;
COL value FORMAT A50
SELECT name, value FROM v$parameter
 WHERE name IN ('db_recovery_file_dest','db_recovery_file_dest_size',
                'log_archive_dest_1');
EXIT;
EOF
