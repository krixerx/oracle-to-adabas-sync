#!/bin/sh
# Dumps one EMPLOYEES record so the test harness can assert on Adabas
# state from outside. Usage: run-dump.sh <personnel-id>
set -e
FUSER=/opt/softwareag/Natural/fuser
NATBIN=/opt/softwareag/Natural/bin
KEY="$1"
[ -z "$KEY" ] && { echo "usage: run-dump.sh <personnel-id>"; exit 2; }

DBMAP=/opt/softwareag/AdabasClient/config/dbmapping.txt
grep -q '^1 = adatcp://adabas:60001' $DBMAP 2>/dev/null || \
  echo '1 = adatcp://adabas:60001' >> $DBMAP

mkdir -p $FUSER/SYNC/SRC $FUSER/SYNC/GP /sync/work
cp /poc/natural/DUMPEMP.NSP $FUSER/SYNC/SRC/
cp $FUSER/SAMP4ONE/SRC/EMPLOYEE.NSD $FUSER/SYNC/SRC/
cp $FUSER/SAMP4ONE/GP/EMPLOYEE.NGD  $FUSER/SYNC/GP/

cd $NATBIN
./ftouch lib=SYNC sm -b -d >/dev/null

printf '%-8s\n' "$KEY" > /sync/work/dump_key.txt
rm -f /sync/work/dump_result.txt

. /opt/softwareag/AdabasClient/INSTALL/aclenv >/dev/null
export TERM=xterm
set +e
./natural udb=1 madio=0 "etid=D$$" \
  "stack=(LOGON SYNC;RUN DUMPEMP;FIN)" </dev/null >/tmp/dump-screen.out 2>&1
rc=$?
if [ $rc -ne 0 ] || [ ! -f /sync/work/dump_result.txt ]; then
  echo "DUMP FAILED (natural rc=$rc)"
  cat /tmp/dump-screen.out
  exit 1
fi
cat /sync/work/dump_result.txt
exit 0
