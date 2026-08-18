#!/bin/sh
# Lab data preparation runner (invoked via docker exec by scripts/seed-source.ps1,
# AFTER that script has added fields BA/BB to Adabas file 12 with ADADBM and
# created file 20 with ADAFDU).
#
# Same headless-Natural mechanics as run-extract.sh - see that file and README.md
# "Spike findings" for why the interactive driver is driven by a stacked command
# list. The one difference that matters: these programs *write* to Adabas, so a
# failure leaves the demo data half-seeded; both are written to be re-runnable
# (each empties what it owns first) so the fix is simply to run them again.
set -e
FUSER=/opt/softwareag/Natural/fuser
NATBIN=/opt/softwareag/Natural/bin

DBMAP=/opt/softwareag/AdabasClient/config/dbmapping.txt
grep -q '^1 = adatcp://adabas:60001' $DBMAP 2>/dev/null || \
  echo '1 = adatcp://adabas:60001' >> $DBMAP

mkdir -p $FUSER/EXTRACT/SRC $FUSER/EXTRACT/GP
cp /poc/natural/SEEDVEH.NSP  $FUSER/EXTRACT/SRC/
cp /poc/natural/SEEDFIN.NSP  $FUSER/EXTRACT/SRC/
cp /poc/natural/VEHICLES.NSD $FUSER/EXTRACT/SRC/
cp /poc/natural/TRAFFINE.NSD $FUSER/EXTRACT/SRC/

cd $NATBIN
./ftouch lib=EXTRACT sm -b -d >/dev/null

. /opt/softwareag/AdabasClient/INSTALL/aclenv >/dev/null
export TERM=xterm
rm -f /tmp/seed_counts.txt /tmp/seed_fine_counts.txt
set +e
# READ+CATALOG regenerates the .NGDs from the DDM sources, which carry the
# fields added to file 12 and the whole of file 20 - without it the seed
# programs will not compile (NAT0981).
# SEEDVEH must run before SEEDFIN: the fines are raised against the plates
# SEEDVEH creates, including the suffixed ones.
./natural udb=1 madio=0 "etid=S$$" \
  "stack=(LOGON EXTRACT;READ VEHICLES;CATALOG;READ TRAFFINE;CATALOG;RUN SEEDVEH;RUN SEEDFIN;FIN)" \
  </dev/null >/tmp/seed-screen.out 2>&1
rc=$?
if [ $rc -ne 0 ] || [ ! -f /tmp/seed_counts.txt ] || [ ! -f /tmp/seed_fine_counts.txt ]; then
  echo "SEED FAILED (natural rc=$rc). Screen output:"
  cat /tmp/seed-screen.out
  exit 1
fi
cat /tmp/seed_counts.txt /tmp/seed_fine_counts.txt
exit 0
