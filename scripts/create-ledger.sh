#!/bin/sh
# Creates the sync apply-watermark file (Adabas file 99, SYNCLEDGER)
# via ADAFDU. Runs INSIDE the o2a-adabas container.
# Idempotent: if file 99 already exists, ADAFDU reports it and we treat
# that as success rather than an error (re-running the lab setup is normal).
#
# The adabas service does not bind-mount the POC folder, so the caller
# docker-cp's LEDGER.fdt / LEDGER.fdu to /tmp first.
set -e
. /opt/softwareag/Adabas/INSTALL/adaenv >/dev/null 2>&1

DBID=${DBID:-1}
FILE=${FILE:-99}

FDUFDT=/tmp/LEDGER.fdt
export FDUFDT

{
  echo "dbid=$DBID"
  echo "file=$FILE"
  cat /tmp/LEDGER.fdu
} > /tmp/ledger.fduinput

set +e
out=$(adafdu < /tmp/ledger.fduinput 2>&1)
rc=$?
echo "$out"
if [ $rc -ne 0 ]; then
  # already-loaded file is not a failure for a re-run
  echo "$out" | grep -q "ANYLOAD\|already loaded" && {
    echo "--- file $FILE already exists, nothing to do ---"
    exit 0
  }
  exit $rc
fi
exit 0
