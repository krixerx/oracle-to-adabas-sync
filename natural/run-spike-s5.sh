#!/bin/sh
# Gating spike S5 (second half): prove Adabas file 99 is usable
# from Natural. The file itself is created by scripts/create-ledger.sh
# (ADAFDU) inside the adabas container.
# LEDGER.NSD is hand-authored from LEDGER.fdt - Natural CE has no SYSDDM,
# so the DDM is cataloged with a stacked "READ LEDGER;CATALOG"
# (the migration lab spike finding, same trick as VEHICLES).
set -e
FUSER=/opt/softwareag/Natural/fuser
NATBIN=/opt/softwareag/Natural/bin

DBMAP=/opt/softwareag/AdabasClient/config/dbmapping.txt
grep -q '^1 = adatcp://adabas:60001' $DBMAP 2>/dev/null || \
  echo '1 = adatcp://adabas:60001' >> $DBMAP

mkdir -p $FUSER/SPIKE/SRC $FUSER/SPIKE/GP
cp /poc/natural/SPIKELED.NSP $FUSER/SPIKE/SRC/
cp /poc/natural/LEDGER.NSD   $FUSER/SPIKE/SRC/

cd $NATBIN
./ftouch lib=SPIKE sm -b -d >/dev/null

. /opt/softwareag/AdabasClient/INSTALL/aclenv >/dev/null
export TERM=xterm
rm -f /poc/data/spike_s5_result.txt
set +e
./natural udb=1 madio=0 "etid=L$$" \
  "stack=(LOGON SPIKE;READ LEDGER;CATALOG;RUN SPIKELED;FIN)" \
  </dev/null >/tmp/spike-s5-screen.out 2>&1
rc=$?
echo "--- natural rc=$rc ---"
if [ ! -f /poc/data/spike_s5_result.txt ]; then
  echo "S5 FAILED: no result file produced. Screen output:"
  cat /tmp/spike-s5-screen.out
  exit 1
fi
echo "--- result file ---"
cat /poc/data/spike_s5_result.txt
exit 0
