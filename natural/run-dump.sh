#!/bin/sh
# Dumps one TRAFFINE record so the test harness can assert on Adabas
# state from outside. Usage: run-dump.sh <fine-no>
set -e
FUSER=/opt/softwareag/Natural/fuser
NATBIN=/opt/softwareag/Natural/bin
KEY="$1"
[ -z "$KEY" ] && { echo "usage: run-dump.sh <fine-no>"; exit 2; }

DBMAP=/opt/softwareag/AdabasClient/config/dbmapping.txt
grep -q '^1 = adatcp://adabas:60001' $DBMAP 2>/dev/null || \
  echo '1 = adatcp://adabas:60001' >> $DBMAP

mkdir -p $FUSER/SYNC/SRC $FUSER/SYNC/GP /sync/work
cp /poc/natural/DUMPFIN.NSP  $FUSER/SYNC/SRC/
cp /poc/natural/TRAFFINE.NSD $FUSER/SYNC/SRC/

cd $NATBIN
./ftouch lib=SYNC sm -b -d >/dev/null

# %-10s: FINE-NO is A10 and the program reads a fixed-width key, so the
# value has to be padded to the full field width or the FIND misses.
printf '%-10s\n' "$KEY" > /sync/work/dump_key.txt
rm -f /sync/work/dump_result.txt

. /opt/softwareag/AdabasClient/INSTALL/aclenv >/dev/null
export TERM=xterm
set +e
./natural udb=1 madio=0 "etid=D$$" \
  "stack=(LOGON SYNC;READ TRAFFINE;CATALOG;RUN DUMPFIN;FIN)" \
  </dev/null >/tmp/dump-screen.out 2>&1
rc=$?
if [ $rc -ne 0 ] || [ ! -f /sync/work/dump_result.txt ]; then
  echo "DUMP FAILED (natural rc=$rc)"
  cat /tmp/dump-screen.out
  exit 1
fi
cat /sync/work/dump_result.txt
exit 0
