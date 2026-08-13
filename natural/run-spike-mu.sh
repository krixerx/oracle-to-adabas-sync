#!/bin/sh
# Gating spike S4 runner: prove Natural CE can WRITE to Adabas
# headlessly. Same install + headless-driver pattern as run-extract.sh
# (Natural CE has no batch mode - the migration lab spike finding).
set -e
FUSER=/opt/softwareag/Natural/fuser
NATBIN=/opt/softwareag/Natural/bin

# DBID 1 -> adabas container (idempotent; dbmapping.txt is image-local)
DBMAP=/opt/softwareag/AdabasClient/config/dbmapping.txt
grep -q '^1 = adatcp://adabas:60001' $DBMAP 2>/dev/null || \
  echo '1 = adatcp://adabas:60001' >> $DBMAP

mkdir -p $FUSER/SPIKE/SRC $FUSER/SPIKE/GP
cp /poc/natural/SPIKEMU.NSP $FUSER/SPIKE/SRC/
cp $FUSER/SAMP4ONE/SRC/EMPLOYEE.NSD $FUSER/SPIKE/SRC/
cp $FUSER/SAMP4ONE/GP/EMPLOYEE.NGD  $FUSER/SPIKE/GP/

cd $NATBIN
./ftouch lib=SPIKE sm -b -d >/dev/null

. /opt/softwareag/AdabasClient/INSTALL/aclenv >/dev/null
export TERM=xterm
rm -f /poc/data/spike_mu_result.txt
set +e
# unique ETID per run (a stale ET user otherwise trips resp 48/8);
# madio=0 lifts the 512 DB-call limit (NAT1009)
./natural udb=1 madio=0 "etid=S$$" \
  "stack=(LOGON SPIKE;RUN SPIKEMU;FIN)" \
  </dev/null >/tmp/spike-mu-screen.out 2>&1
rc=$?
echo "--- natural rc=$rc ---"
if [ ! -f /poc/data/spike_mu_result.txt ]; then
  echo "S4b FAILED: no result file produced. Screen output:"
  cat /tmp/spike-mu-screen.out
  exit 1
fi
echo "--- result file ---"
cat /poc/data/spike_mu_result.txt
echo "--- screen output (compile/runtime messages) ---"
cat /tmp/spike-mu-screen.out
exit 0
