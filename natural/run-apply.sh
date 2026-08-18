#!/bin/sh
# Applies ONE mapped batch to Adabas (spec C6).
#
# Usage: run-apply.sh <batch-dir-name>      e.g. run-apply.sh batch-000042
#
# Stages /sync/inbox/<batch>/ into /sync/work (the Natural programs use
# fixed work-file paths - Natural CE has no batch mode, so there are no
# parameters to pass), runs APPLYFIN headlessly, then acknowledges the
# batch by RENAMING its directory to /sync/applied or /sync/rejected.
# The rename is the acknowledgement: atomic on one filesystem, and it is
# what makes the file protocol a real queue.
set -e
FUSER=/opt/softwareag/Natural/fuser
NATBIN=/opt/softwareag/Natural/bin
BATCH="$1"

if [ -z "$BATCH" ]; then
  echo "usage: run-apply.sh <batch-dir-name>"
  exit 2
fi

INBOX=/sync/inbox/$BATCH
if [ ! -f "$INBOX/_COMPLETE" ]; then
  # No _COMPLETE means the producer may still be writing. Never read it.
  echo "SKIP $BATCH: no _COMPLETE marker"
  exit 3
fi

DBMAP=/opt/softwareag/AdabasClient/config/dbmapping.txt
grep -q '^1 = adatcp://adabas:60001' $DBMAP 2>/dev/null || \
  echo '1 = adatcp://adabas:60001' >> $DBMAP

mkdir -p $FUSER/SYNC/SRC $FUSER/SYNC/GP
cp /poc/natural/APPLYFIN.NSP $FUSER/SYNC/SRC/
cp /poc/natural/APPLYVEH.NSP $FUSER/SYNC/SRC/
cp /poc/natural/TRAFFINE.NSD $FUSER/SYNC/SRC/
cp /poc/natural/VEHICLES.NSD $FUSER/SYNC/SRC/
cp /poc/natural/LEDGER.NSD   $FUSER/SYNC/SRC/

cd $NATBIN
./ftouch lib=SYNC sm -b -d >/dev/null

# Stage the batch. Every work file must EXIST even when empty: an absent
# work file makes Natural fail at OPEN, whereas an empty one correctly
# means "this MU/PE set is empty" (the contract's completeness rule).
rm -rf /sync/work
mkdir -p /sync/work
for f in traffic_fine traffic_fine_offence traffic_fine_payment vehicle vehicle_plate; do
  if [ -f "$INBOX/$f.dat" ]; then
    cp "$INBOX/$f.dat" /sync/work/
  else
    : > /sync/work/$f.dat
  fi
done
cp "$INBOX/batch_info.dat" /sync/work/

. /opt/softwareag/AdabasClient/INSTALL/aclenv >/dev/null
export TERM=xterm
set +e
# unique ETID per run: an aborted session leaves a stale ET user in the
# Adabas user queue and a fixed ETID would then hit resp 48/8
#
# The DDMs are re-catalogued every run: CE has no SYSDDM, so this is what
# makes the library self-healing after `docker compose down -v`.
#
# BOTH appliers run in ONE Natural session, and APPLYFIN runs LAST because it
# is the one that writes the ledger: the watermark must move after the work,
# not before it. A batch can carry both aggregates, and splitting them across
# two sessions would let one commit while the other failed.
./natural udb=1 madio=0 "etid=A$$" \
  "stack=(LOGON SYNC;READ LEDGER;CATALOG;READ TRAFFINE;CATALOG;READ VEHICLES;CATALOG;RUN APPLYVEH;RUN APPLYFIN;FIN)" \
  </dev/null >/tmp/apply-screen.out 2>&1
rc=$?
set -e

if [ $rc -ne 0 ] || [ ! -f /sync/work/apply_result.txt ]; then
  echo "APPLY FAILED for $BATCH (natural rc=$rc)"
  cat /tmp/apply-screen.out
  exit 1
fi

[ -f /sync/work/apply_result_veh.txt ] && cat /sync/work/apply_result_veh.txt
cat /sync/work/apply_result.txt

# A refusal is a deliberate outcome, not a crash: APPLYVEH reports it and
# keeps going so the ledger still moves. The exit code is set HERE, and it
# is what sends the batch to rejected/ and halts the pump.
if grep -q 'REFUSED-\|REJECTED-' /sync/work/apply_result_veh.txt 2>/dev/null; then
  echo "APPLY REFUSED something in $BATCH - see above"
  exit 1
fi
exit 0

# NOTE - where the acknowledgement happens, and why it is not here.
#
# The design says the consumer acknowledges a batch by RENAMING its
# directory to applied/ or rejected/, which is atomic on one filesystem.
# That rename cannot be done from inside this container in the lab:
# Docker Desktop's Windows bind mount refuses to rename a directory
# ("mv: Permission denied") even with 0777 on every level. The HOST can
# do it - a same-volume Move-Item on NTFS is atomic - so scripts/sync-pump.ps1
# performs the acknowledgement based on this script's exit code.
#
# LAB DIVERGENCE, stated so nobody re-discovers it: on a real Linux
# deployment the applier would rename the directory itself, immediately
# after ET, and this split would not exist. The split costs nothing in
# correctness: a crash between the apply and the rename simply leaves the
# batch in the inbox to be re-applied, and re-applying is a no-op by
# construction (ledger watermark + compare-before-write).
