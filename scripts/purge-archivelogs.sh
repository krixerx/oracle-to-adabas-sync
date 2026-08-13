#!/bin/sh
# Purges old archive logs. Runs INSIDE o2a-oracle.
#
# WHY THIS EXISTS: turning on ARCHIVELOG without a purge job fills the
# disk. In this lab that takes days; it is the single most likely way the
# the lab environment dies quietly (spec C1, gating spike S1).
#
# WHY IT USES `find` AND NOT rman: gvenzl/oracle-free:23-slim ships
# without rman. enable-archivelog.sh therefore points archiving at a
# plain directory outside the FRA, so deleting files by age is both
# sufficient and safe - there is no FRA space accounting to get out of
# step with the filesystem. Stale controlfile records for the deleted
# logs age out on their own after control_file_record_keep_time (7 days
# by default) and are harmless meanwhile.
#
# HAZARD - READ BEFORE CHANGING THE AGE:
# Deleting an archive log the capture process has not consumed yet is
# UNRECOVERABLE data loss for CDC: those changes exist nowhere else.
# The default 24h window is safe in a lab where the connector is either
# running or the lab is idle. In PRODUCTION the deletion policy must be
# driven by the connector's committed SCN - only delete logs whose
# NEXT_CHANGE# is below the offset Debezium has persisted - not by age.
#
# Usage:  purge-archivelogs.sh [hours]     default 24
set -e
HOURS=${1:-24}
ARCH_DIR=${ARCH_DIR:-/opt/oracle/oradata/ARCH}
ORACLE_SID=${ORACLE_SID:-FREE}
export ORACLE_SID

# find -mmin takes minutes; keep the interface in hours for the operator
MINUTES=$((HOURS * 60))

echo "--- archive logs before ---"
du -sh "$ARCH_DIR" 2>/dev/null || echo "  (no archive directory yet)"
before=$(find "$ARCH_DIR" -type f -name '*.dbf' 2>/dev/null | wc -l)
echo "  files: $before"

echo "--- lowest SCN still needed by capture (informational) ---"
# If a connector offset exists, show it next to the oldest log so an
# operator can see whether the purge is about to cross the capture point.
sqlplus -s / as sysdba <<'EOF'
SET LINESIZE 200 PAGESIZE 50 FEEDBACK OFF
COL oldest FORMAT A20
SELECT MIN(first_change#) AS oldest_scn_on_disk,
       MAX(next_change#)  AS newest_scn_on_disk
  FROM v$archived_log WHERE deleted = 'NO';
EXIT;
EOF

echo "--- deleting archive logs older than ${HOURS}h ---"
find "$ARCH_DIR" -type f -name '*.dbf' -mmin +${MINUTES} -print -delete 2>/dev/null | wc -l \
  | sed 's/^/  deleted files: /'

echo "--- archive logs after ---"
du -sh "$ARCH_DIR" 2>/dev/null
after=$(find "$ARCH_DIR" -type f -name '*.dbf' 2>/dev/null | wc -l)
echo "  files: $after"
