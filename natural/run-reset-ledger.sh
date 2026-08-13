#!/bin/sh
# Clears the sync apply watermark. TEST SUPPORT ONLY - see RESETLED.NSP.
set -e
FUSER=/opt/softwareag/Natural/fuser
NATBIN=/opt/softwareag/Natural/bin

DBMAP=/opt/softwareag/AdabasClient/config/dbmapping.txt
grep -q '^1 = adatcp://adabas:60001' $DBMAP 2>/dev/null || \
  echo '1 = adatcp://adabas:60001' >> $DBMAP

mkdir -p $FUSER/SYNC/SRC $FUSER/SYNC/GP /sync/work
cp /poc/natural/RESETLED.NSP $FUSER/SYNC/SRC/
cp /poc/natural/LEDGER.NSD   $FUSER/SYNC/SRC/

cd $NATBIN
./ftouch lib=SYNC sm -b -d >/dev/null

. /opt/softwareag/AdabasClient/INSTALL/aclenv >/dev/null
export TERM=xterm
rm -f /sync/work/reset_result.txt
set +e
./natural udb=1 madio=0 "etid=R$$" \
  "stack=(LOGON SYNC;READ LEDGER;CATALOG;RUN RESETLED;FIN)" \
  </dev/null >/tmp/reset-screen.out 2>&1
rc=$?
if [ $rc -ne 0 ] || [ ! -f /sync/work/reset_result.txt ]; then
  echo "LEDGER RESET FAILED (natural rc=$rc)"
  cat /tmp/reset-screen.out
  exit 1
fi
cat /sync/work/reset_result.txt
exit 0
