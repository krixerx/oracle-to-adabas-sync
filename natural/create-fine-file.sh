#!/bin/sh
# Creates the traffic-fine file (Adabas file 20, TRAFFINE) with ADAFDU.
# Runs INSIDE the o2a-adabas container.
#
# The adabas service does not bind-mount the POC folder (only natural does), so
# scripts/seed-source.ps1 docker-cp's TRAFFINE.fdt / TRAFFINE.fdu to /tmp first.
#
# Idempotent: an already-loaded file is reported by ADAFDU and treated as
# success, because re-running the lab setup is normal. The data in it is
# refreshed separately by SEEDFIN.NSP, which deletes before it stores.
set -e
. /opt/softwareag/Adabas/INSTALL/adaenv >/dev/null 2>&1

DBID=${DBID:-1}
FILE=${FILE:-20}

FDUFDT=/tmp/TRAFFINE.fdt
export FDUFDT

{
  echo "dbid=$DBID"
  echo "file=$FILE"
  cat /tmp/TRAFFINE.fdu
} > /tmp/traffine.fduinput

set +e
out=$(adafdu < /tmp/traffine.fduinput 2>&1)
rc=$?
echo "$out"
if [ $rc -ne 0 ]; then
  echo "$out" | grep -q "ANYLOAD\|already loaded" && {
    echo "--- file $FILE already exists, nothing to do ---"
    exit 0
  }
  exit $rc
fi
exit 0
