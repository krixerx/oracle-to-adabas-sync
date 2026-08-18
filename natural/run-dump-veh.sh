#!/bin/sh
# Dumps every VEHICLES record sharing one base VIN, so the test harness can
# assert on Adabas state from outside. Usage: run-dump-veh.sh <base-vin>
#
# A vehicle is a SET of Adabas records (one per plate), which is why this
# prints NPLATES and numbers each one.
set -e
FUSER=/opt/softwareag/Natural/fuser
NATBIN=/opt/softwareag/Natural/bin
KEY="$1"
[ -z "$KEY" ] && { echo "usage: run-dump-veh.sh <base-vin>"; exit 2; }

DBMAP=/opt/softwareag/AdabasClient/config/dbmapping.txt
grep -q '^1 = adatcp://adabas:60001' $DBMAP 2>/dev/null || \
  echo '1 = adatcp://adabas:60001' >> $DBMAP

mkdir -p $FUSER/SYNC/SRC $FUSER/SYNC/GP /sync/work
cp /poc/natural/DUMPVEH.NSP  $FUSER/SYNC/SRC/
cp /poc/natural/VEHICLES.NSD $FUSER/SYNC/SRC/

cd $NATBIN
./ftouch lib=SYNC sm -b -d >/dev/null

# %-17s: the program reads a fixed-width A17 key, so the value has to be
# padded to the full field width or the comparison misses.
printf '%-17s\n' "$KEY" > /sync/work/dump_key.txt
rm -f /sync/work/dump_result.txt

. /opt/softwareag/AdabasClient/INSTALL/aclenv >/dev/null
export TERM=xterm
set +e
./natural udb=1 madio=0 "etid=W$$" \
  "stack=(LOGON SYNC;READ VEHICLES;CATALOG;RUN DUMPVEH;FIN)" \
  </dev/null >/tmp/dumpveh-screen.out 2>&1
rc=$?
if [ $rc -ne 0 ] || [ ! -f /sync/work/dump_result.txt ]; then
  echo "DUMP FAILED (natural rc=$rc)"
  cat /tmp/dumpveh-screen.out
  exit 1
fi
cat /sync/work/dump_result.txt
exit 0
