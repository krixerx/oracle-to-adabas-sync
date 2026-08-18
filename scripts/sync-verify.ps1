# Sync acceptance harness: the ten success criteria from the spec (§7).
# Prints "SYNC VERIFIED: n/n", in the spirit of the migration lab's "VERIFIED: 5/5".
#
# Each test makes a change in ORACLE, runs the sync, and asserts on ADABAS.
# Assertions read Adabas through DUMPFIN - never through the sync's own
# bookkeeping - so a test cannot pass by the pipeline agreeing with itself.
#
# Usage:  powershell -File scripts\sync-verify.ps1
$ErrorActionPreference = "Stop"
$poc = Split-Path -Parent $PSScriptRoot
Set-Location $poc

$script:Pass = 0
$script:Fail = 0
$script:Skip = 0
$script:Results = @()

$TESTKEY = 'F000000005'   # existing fine, has 2 offence codes (MU)
$NEWKEY  = 'FZZ9999999'   # synthetic, created and removed by test 2/3
$NEWISN  = 9999999        # source_isn for the synthetic fine (UNIQUE column)
$VEHKEY  = 'CITZZ1JZW00000014'   # a vehicle with TWO plates = two Adabas records

# ---------------------------------------------------------------- helpers
function Sql([string]$sql, [string]$user = "pocapp/pocapp") {
    # sqlplus takes ONE statement per line: "UPDATE ...; COMMIT;" on a single
    # line raises ORA-03405 ("no additional text should follow"). Normalise
    # here rather than relying on every call site to remember.
    $sql = ($sql -replace ';\s+', ";`n")
    $tmp = Join-Path $env:TEMP "poc2_sql.sql"
    [System.IO.File]::WriteAllText($tmp, "SET FEEDBACK OFF`n$sql`nEXIT;`n",
        (New-Object System.Text.UTF8Encoding($false)))
    docker cp $tmp "o2a-oracle:/tmp/poc2_sql.sql" | Out-Null
    $out = docker exec o2a-oracle sqlplus -s "$user@//localhost:1521/FREEPDB1" `@/tmp/poc2_sql.sql 2>&1
    if ($out -match "ORA-\d+") { throw "SQL failed: $($out -join ' ')" }
    return $out
}

function Dump([string]$key) {
    $out = docker exec o2a-natural sh /poc/natural/run-dump.sh $key 2>&1
    $map = @{}
    foreach ($line in $out) {
        $l = ($line -replace "`e\[[0-9;]*[a-zA-Z]", "").Trim()
        if ($l -match '^([A-Z0-9]+)=(.*)$') { $map[$Matches[1]] = $Matches[2].Trim() }
        if ($l -match '^NOTFOUND') { $map['NOTFOUND'] = $true }
        if ($l -match '^FOUND') { $map['FOUND'] = $true }
    }
    return $map
}

function DumpVeh([string]$vin) {
    $out = docker exec o2a-natural sh /poc/natural/run-dump-veh.sh $vin 2>&1
    $map = @{}
    foreach ($line in $out) {
        $l = ($line -replace "`e\[[0-9;]*[a-zA-Z]", "").Trim()
        if ($l -match '^([A-Z0-9]+)=(.*)$') { $map[$Matches[1]] = $Matches[2].Trim() }
    }
    return $map
}

function Resolve-Java {
    # JAVA_HOME first (what sync-start.cmd uses), then whatever is on PATH.
    # Never hardcode an install path - it only works on the machine that wrote it.
    if ($env:JAVA_HOME) {
        $j = Join-Path $env:JAVA_HOME "bin\java.exe"
        if (Test-Path $j) { return $j }
    }
    $onPath = Get-Command java.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    throw "Java not found. Set JAVA_HOME to a JDK 21 install, or put java.exe on PATH."
}

function Start-Capture([int]$seconds = 60) {
    $java = Resolve-Java
    $log  = Join-Path $poc "sync\capture.log"
    if (Test-Path $log) { Remove-Item $log -Force }
    $p = Start-Process -FilePath $java -PassThru -WindowStyle Hidden `
        -ArgumentList @("-jar", "capture\target\oracle-capture.jar",
                        "capture\capture-local.properties", "$seconds") `
        -RedirectStandardOutput $log -RedirectStandardError (Join-Path $poc "sync\capture.err")
    # The connector needs ~25 s to mine the dictionary and reach steady state;
    # starting a test before then would miss the change and fail spuriously.
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern "next batch" -Quiet)) { break }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 3
    return $p
}

function Stop-Capture($p) {
    if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(15000) | Out-Null }
}

function Sync-Once([int]$waitSeconds = 18) {
    Start-Sleep -Seconds $waitSeconds
    & (Join-Path $poc "scripts\sync-pump.ps1") | Out-Null
}

function Reset-Ledger {
    docker exec o2a-natural sh /poc/natural/run-reset-ledger.sh 2>&1 | Out-Null
}

function Clear-SyncDirs {
    foreach ($d in @("outbox", "inbox", "applied", "rejected", "state")) {
        $p = Join-Path $poc "sync\$d"
        if (Test-Path $p) {
            Remove-Item -Recurse -Force $p
        }
    }
}

function Check([int]$n, [string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { $script:Pass++ } else { $script:Fail++ }
    $status = if ($ok) { "PASS" } else { "FAIL" }
    $script:Results += ("  {0}  {1,2}. {2}{3}" -f $status, $n, $name.PadRight(46),
        $(if ($detail) { "  ($detail)" } else { "" }))
    Write-Host ("  {0}  {1,2}. {2}" -f $status, $n, $name) -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
    if (-not $ok -and $detail) { Write-Host "        $detail" -ForegroundColor DarkYellow }
}

# A criterion that is deliberately out of scope for this round. It still counts
# towards the total - the suite reports 9/10, not 9/9, because the tenth
# criterion exists and is knowingly unmet - but it must NOT make the run exit
# non-zero, or the advertised result and the exit code disagree.
function Skip([int]$n, [string]$name, [string]$detail) {
    $script:Skip++
    $script:Results += ("  SKIP  {0,2}. {1}  ({2})" -f $n, $name.PadRight(46), $detail)
    Write-Host ("  SKIP  {0,2}. {1}" -f $n, $name) -ForegroundColor DarkGray
    Write-Host "        $detail" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- start
Write-Host ""
Write-Host "=== Oracle -> Adabas sync verification ===" -ForegroundColor Cyan
Write-Host ""

Clear-SyncDirs
Reset-Ledger

# Establish a known starting point in BOTH databases so the tests are
# repeatable: re-running the suite must not depend on what the last run left.
# The payment delete is not optional housekeeping: test 5 inserts seq_no 70 and
# asserts CPAY=1, so both the primary key and the count assertion depend on the
# fine starting with NO payments - which is how the seed leaves it. Without
# this, the suite passes once and then fails on ORA-00001 for ever after.
Sql @"
UPDATE pocapp.traffic_fine SET location='BASELINE LOC', amount=85 WHERE fine_no='$TESTKEY';
DELETE FROM pocapp.traffic_fine_offence
 WHERE fine_id=(SELECT fine_id FROM pocapp.traffic_fine WHERE fine_no='$TESTKEY')
   AND seq_no > 2;
DELETE FROM pocapp.traffic_fine_payment
 WHERE fine_id=(SELECT fine_id FROM pocapp.traffic_fine WHERE fine_no='$TESTKEY');
DELETE FROM pocapp.traffic_fine_offence
 WHERE fine_id=(SELECT fine_id FROM pocapp.traffic_fine WHERE fine_no='$NEWKEY');
DELETE FROM pocapp.traffic_fine_payment
 WHERE fine_id=(SELECT fine_id FROM pocapp.traffic_fine WHERE fine_no='$NEWKEY');
DELETE FROM pocapp.traffic_fine WHERE fine_no='$NEWKEY';
UPDATE pocapp.vehicle SET color='BLANCHE' WHERE vin='$VEHKEY';
UPDATE pocapp.vehicle_plate SET expiry_date=NULL
 WHERE vehicle_id=(SELECT vehicle_id FROM pocapp.vehicle WHERE vin='$VEHKEY');
COMMIT;
"@ | Out-Null

$cap = Start-Capture 300
try {
    Sync-Once | Out-Null      # drain the baseline change so tests start clean

    # -------------------------------------------------------------- 1
    Sql "UPDATE pocapp.traffic_fine SET location='T1-MUSCAT EXPWY' WHERE fine_no='$TESTKEY'; COMMIT;" | Out-Null
    Sync-Once | Out-Null
    $d = Dump $TESTKEY
    Check 1 "scalar update propagates" ($d['LOC'] -eq 'T1-MUSCAT EXPWY') "LOC=$($d['LOC'])"

    # -------------------------------------------------------------- 2
    Sql @"
INSERT INTO pocapp.traffic_fine (source_isn, fine_no, plate_no, offence_date, location,
       amount, status_code, status, offender_national_id)
VALUES ($NEWISN, '$NEWKEY', '344RG94', DATE '2026-02-03', 'T2-NIZWA ROAD',
        45.50, 'I', 'Issued', '50000100');
INSERT INTO pocapp.traffic_fine_offence (fine_id, seq_no, offence_code, offence_desc)
 SELECT fine_id, 1, 'PARK', 'Illegal parking' FROM pocapp.traffic_fine WHERE fine_no='$NEWKEY';
COMMIT;
"@ | Out-Null
    Sync-Once | Out-Null
    $d = Dump $NEWKEY
    # status 'Issued' must come back as the CODE 'I', and the offence
    # description as 'PARK' - proving the reverse CODE_LOOKUP ran on both
    # the parent and the MU, not just that a record arrived. The amount
    # proves the decimal survived the text round trip.
    Check 2 "insert propagates (incl. reverse code lookup)" `
        ($d['FOUND'] -and $d['LOC'] -eq 'T2-NIZWA ROAD' -and $d['STATUS'] -eq 'I' `
         -and $d['OFF1'] -eq 'PARK' -and $d['AMOUNT'] -eq '45.50') `
        "FOUND=$($d['FOUND']) LOC=$($d['LOC']) STATUS=$($d['STATUS']) OFF1=$($d['OFF1']) AMOUNT=$($d['AMOUNT'])"

    # -------------------------------------------------------------- 3
    # NOTHING IS EVER DELETED (2026-08-18, revising O4). A fine goes away by
    # being CANCELLED - status 'C' - which travels as an ordinary update. The
    # second half proves the other side of the rule: a physical delete is
    # REFUSED by the applier rather than obeyed, so history cannot be
    # destroyed by a mistake in Oracle.
    Sql "UPDATE pocapp.traffic_fine SET status_code='C', status='Cancelled' WHERE fine_no='$NEWKEY'; COMMIT;" | Out-Null
    Sync-Once | Out-Null
    $d = Dump $NEWKEY
    $cancelled = ($d['FOUND'] -and $d['STATUS'] -eq 'C')

    # Now the refusal. Driven through run-apply.sh directly rather than the
    # pump: a refused batch deliberately halts the pump and does NOT advance
    # the watermark, so letting it into the queue would block every later
    # test - which is exactly the behaviour being asserted.
    Sql "DELETE FROM pocapp.traffic_fine_offence WHERE fine_id=(SELECT fine_id FROM pocapp.traffic_fine WHERE fine_no='$NEWKEY'); DELETE FROM pocapp.traffic_fine WHERE fine_no='$NEWKEY'; COMMIT;" | Out-Null
    Start-Sleep -Seconds 12
    $delBatch = Get-ChildItem (Join-Path $poc "sync\outbox") -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName "_COMPLETE") } | Sort-Object Name | Select-Object -First 1
    $refused = $false
    if ($delBatch) {
        $inDir = "/sync/outbox/$($delBatch.Name)"; $outDir = "/sync/inbox/$($delBatch.Name)"
        curl.exe -s -u cluster:cluster --max-time 300 `
            "http://localhost:8081/hop/execWorkflow/?workflow=/poc/hop/workflows/sync-apply.hwf&runConfig=local&level=Basic&BATCH_IN=$inDir&BATCH_OUT=$outDir" | Out-Null
        & (Join-Path $poc "scripts\make-batch-info.ps1") $delBatch.Name | Out-Null
        $out = (docker exec o2a-natural sh /poc/natural/run-apply.sh $delBatch.Name 2>&1) -join " "
        $refused = ($out -match "REFUSED-DELETE" -and $out -match "LEDGER-NOT-ADVANCED")
        # discard it: the batch is unappliable by design, and leaving it in the
        # queue would halt the pump for every later test
        Remove-Item -Recurse -Force $delBatch.FullName
        Remove-Item -Recurse -Force (Join-Path $poc "sync\inbox\$($delBatch.Name)") -ErrorAction SilentlyContinue
    }
    $stillThere = (Dump $NEWKEY)['FOUND']
    Check 3 "cancellation propagates; a delete is refused" `
        ($cancelled -and $refused -and $stillThere) `
        "cancelled=$cancelled refused=$refused adabasRecordSurvived=$stillThere"

    # -------------------------------------------------------------- 4
    # The MU case that silently corrupts if the applier forgets to RESET
    # trailing occurrences before lowering the count.
    Sql @"
INSERT INTO pocapp.traffic_fine_offence (fine_id, seq_no, offence_code, offence_desc)
 SELECT fine_id, 50, 'SBLT', 'Seat belt not worn' FROM pocapp.traffic_fine WHERE fine_no='$TESTKEY';
INSERT INTO pocapp.traffic_fine_offence (fine_id, seq_no, offence_code, offence_desc)
 SELECT fine_id, 60, 'MOBP', 'Using a mobile phone while driving' FROM pocapp.traffic_fine WHERE fine_no='$TESTKEY';
COMMIT;
"@ | Out-Null
    Sync-Once | Out-Null
    $grow = Dump $TESTKEY
    # seq_no 50 and 60 must arrive as occurrences 3 and 4: Adabas occurrences
    # are dense, so the capture renumbers them 1..n.
    $grewOk = ($grow['COFF'] -eq '4' -and $grow['OFF3'] -eq 'SBLT' -and $grow['OFF4'] -eq 'MOBP')

    Sql "DELETE FROM pocapp.traffic_fine_offence WHERE fine_id=(SELECT fine_id FROM pocapp.traffic_fine WHERE fine_no='$TESTKEY') AND seq_no >= 50; COMMIT;" | Out-Null
    Sync-Once | Out-Null
    $shrink = Dump $TESTKEY
    # Assert the residue is GONE, not merely uncounted: OFF3/OFF4 are read
    # beyond the count deliberately.
    $shrankOk = ($shrink['COFF'] -eq '2' -and $shrink['OFF3'] -eq '' -and $shrink['OFF4'] -eq '')
    Check 4 "MU set grows and shrinks, no residue" ($grewOk -and $shrankOk) `
        "grow COFF=$($grow['COFF']) OFF3=$($grow['OFF3']) OFF4=$($grow['OFF4']); shrink COFF=$($shrink['COFF']) OFF3='$($shrink['OFF3'])' OFF4='$($shrink['OFF4'])'"

    # -------------------------------------------------------------- 5
    # Parent and PE child changed in ONE Oracle transaction: both must land
    # together, and the payment must arrive as a dense occurrence with its
    # method description reversed to the A2 code.
    Sql @"
UPDATE pocapp.traffic_fine SET location='T5-SALALAH', amount=77.25 WHERE fine_no='$TESTKEY';
INSERT INTO pocapp.traffic_fine_payment (fine_id, seq_no, paid_date, paid_amount, method_code, method)
 SELECT fine_id, 70, DATE '2026-03-04', 17.25, 'BT', 'Bank transfer'
   FROM pocapp.traffic_fine WHERE fine_no='$TESTKEY';
COMMIT;
"@ | Out-Null
    Sync-Once | Out-Null
    $d = Dump $TESTKEY
    Check 5 "multi-table transaction lands together" `
        ($d['LOC'] -eq 'T5-SALALAH' -and $d['AMOUNT'] -eq '77.25' -and $d['CPAY'] -eq '1' `
         -and $d['PAY1'] -match '20260304/\s*17\.25/BT') `
        "LOC=$($d['LOC']) AMOUNT=$($d['AMOUNT']) CPAY=$($d['CPAY']) PAY1=$($d['PAY1'])"

    # -------------------------------------------------------------- 6
    # Replay an already-applied batch. The ledger guard is deliberately
    # RESET first, so this tests compare-before-write itself rather than
    # the watermark short-circuit.
    $applied = Get-ChildItem (Join-Path $poc "sync\applied") -Directory |
               Sort-Object Name | Select-Object -Last 1
    if ($applied) {
        Reset-Ledger
        Move-Item $applied.FullName (Join-Path $poc "sync\inbox\$($applied.Name)")
        $out = docker exec o2a-natural sh /poc/natural/run-apply.sh $applied.Name 2>&1
        $flat = ($out -join " ")
        Move-Item (Join-Path $poc "sync\inbox\$($applied.Name)") (Join-Path $poc "sync\applied\$($applied.Name)")
        Check 6 "batch replay is a no-op" `
            ($flat -match "NOOP-IDENTICAL" -and $flat -match "updated=\s*0") `
            ($flat -replace '\s+', ' ' | Select-Object -First 1)
    } else {
        Check 6 "batch replay is a no-op" $false "no applied batch to replay"
    }

    # -------------------------------------------------------------- 7
    # A write by the apply-back user must never propagate (loop prevention).
    $before = Dump $TESTKEY
    Sql "UPDATE pocapp.traffic_fine SET location='ECHO-LOC' WHERE fine_no='$TESTKEY'; COMMIT;" "syncapp/syncapp" | Out-Null
    Sync-Once | Out-Null
    $after = Dump $TESTKEY
    Check 7 "SYNCAPP writes are filtered out" `
        ($after['LOC'] -eq $before['LOC'] -and $after['LOC'] -ne 'ECHO-LOC') `
        "Adabas LOC=$($after['LOC']) (expected unchanged $($before['LOC']))"
    # put Oracle back so later assertions are not confused by the echo row
    Sql "UPDATE pocapp.traffic_fine SET location='$($before['LOC'])' WHERE fine_no='$TESTKEY'; COMMIT;" "syncapp/syncapp" | Out-Null

    # -------------------------------------------------------------- 8
    # Crash mid-batch: apply a batch, kill nothing, but simulate the crash
    # window by re-applying an un-acknowledged batch. Nothing may double.
    Sql "UPDATE pocapp.traffic_fine SET location='T8 CRASHTEST' WHERE fine_no='$TESTKEY'; COMMIT;" | Out-Null
    Start-Sleep -Seconds 12
    $ready = Get-ChildItem (Join-Path $poc "sync\outbox") -Directory -ErrorAction SilentlyContinue |
             Where-Object { Test-Path (Join-Path $_.FullName "_COMPLETE") } | Sort-Object Name | Select-Object -First 1
    if ($ready) {
        # map + apply, but do NOT acknowledge - exactly the crash window
        $inDir = "/sync/outbox/$($ready.Name)"; $outDir = "/sync/inbox/$($ready.Name)"
        curl.exe -s -u cluster:cluster --max-time 300 `
            "http://localhost:8081/hop/execWorkflow/?workflow=/poc/hop/workflows/sync-apply.hwf&runConfig=local&level=Basic&BATCH_IN=$inDir&BATCH_OUT=$outDir" | Out-Null
        $manifest = Get-Content (Join-Path $ready.FullName "manifest.json") -Raw | ConvertFrom-Json
        $line = ("{0:d6}{1}" -f [int]$manifest.batch, ([string]$manifest.end_scn).PadLeft(15, '0'))
        $dir = Join-Path $poc "sync\inbox\$($ready.Name)"
        [System.IO.File]::WriteAllText((Join-Path $dir "batch_info.dat"), "$line`n", (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $dir "_COMPLETE"), "", (New-Object System.Text.UTF8Encoding($false)))
        docker exec o2a-natural sh /poc/natural/run-apply.sh $ready.Name 2>&1 | Out-Null
        # "crash" here: no acknowledgement. Restart => re-apply the same batch.
        $again = docker exec o2a-natural sh /poc/natural/run-apply.sh $ready.Name 2>&1
        $flat = ($again -join " ")
        $d = Dump $TESTKEY
        Check 8 "crash mid-batch: re-apply is clean" `
            ($d['LOC'] -eq 'T8 CRASHTEST' -and $flat -match "ALREADY-APPLIED|NOOP-IDENTICAL") `
            "LOC=$($d['LOC']); re-apply said: $(($flat -replace '\s+',' ').Trim())"
        Move-Item $dir (Join-Path $poc "sync\applied\$($ready.Name)") -Force
        Remove-Item -Recurse -Force $ready.FullName
    } else {
        Check 8 "crash mid-batch: re-apply is clean" $false "no batch was produced"
    }

    # -------------------------------------------------------------- 9
    # Adabas outage: stop the nucleus, make changes, restart, drain.
    Write-Host "        (stopping Adabas for the outage test...)" -ForegroundColor DarkGray
    docker compose stop adabas | Out-Null
    Sql "UPDATE pocapp.traffic_fine SET location='T9-OUTAGE-1' WHERE fine_no='$TESTKEY'; COMMIT;" | Out-Null
    Start-Sleep -Seconds 3
    Sql "UPDATE pocapp.traffic_fine SET location='T9-OUTAGE-2' WHERE fine_no='$TESTKEY'; COMMIT;" | Out-Null
    Start-Sleep -Seconds 12
    $queued = (Get-ChildItem (Join-Path $poc "sync\outbox") -Directory -ErrorAction SilentlyContinue).Count
    powershell -File (Join-Path $poc "scripts\lab-up.ps1") | Out-Null
    Start-Sleep -Seconds 5
    Sync-Once 3 | Out-Null
    $d = Dump $TESTKEY
    Check 9 "Adabas outage: changes queue and drain" `
        ($queued -ge 1 -and $d['LOC'] -eq 'T9-OUTAGE-2') `
        "queued=$queued LOC=$($d['LOC'])"

    # -------------------------------------------------------------- 10
    # Conflict detection is a documented stretch goal (spec 5.4): the
    # before-image is available for free thanks to ALL COLUMNS supplemental
    # logging, but the applier does not yet compare against it.
    Skip 10 "conflict detected and routed to rejected/" `
        "out of scope this round (spec 5.4) - the before-image is already free from ALL COLUMNS supplemental logging, but the applier does not compare against it yet"

    # -------------------------------------------------------------- 11
    # The vehicle aggregate, whose shape is the opposite of the fine's:
    # Adabas file 12 holds ONE RECORD PER PLATE, so one Oracle vehicle is a
    # SET of Adabas records. A vehicle attribute has to reach every one of
    # them, while an expiry must land on exactly one.
    $before = DumpVeh $VEHKEY
    Sql @"
UPDATE pocapp.vehicle SET color='T11-VERT' WHERE vin='$VEHKEY';
UPDATE pocapp.vehicle_plate SET expiry_date=DATE '2026-06-30'
 WHERE vehicle_id=(SELECT vehicle_id FROM pocapp.vehicle WHERE vin='$VEHKEY') AND plate_seq=2;
COMMIT;
"@ | Out-Null
    Sync-Once | Out-Null
    $v = DumpVeh $VEHKEY
    Check 11 "vehicle: attribute hits every plate record, expiry one" `
        ($v['NPLATES'] -eq '2' -and $v['COLOR1'] -eq 'T11-VERT' -and $v['COLOR2'] -eq 'T11-VERT' `
         -and $v['EXPIRY1'] -eq '0' -and $v['EXPIRY2'] -eq '20260630' `
         -and $v['VINFULL2'] -eq ($VEHKEY + '1') -and $v['VEHTYPE1'] -eq $before['VEHTYPE1']) `
        "n=$($v['NPLATES']) colours=$($v['COLOR1'])/$($v['COLOR2']) expiry=$($v['EXPIRY1'])/$($v['EXPIRY2']) vin2=$($v['VINFULL2']) type=$($v['VEHTYPE1'])"

} finally {
    Stop-Capture $cap
}

# ---------------------------------------------------------------- report
$total = $script:Pass + $script:Fail + $script:Skip
Write-Host ""
Write-Host "----------------------------------------------------------------"
if ($script:Fail -eq 0) {
    $note = if ($script:Skip -gt 0) { "   ($($script:Skip) skipped by design)" } else { "" }
    Write-Host ("SYNC VERIFIED: {0}/{1}{2}" -f $script:Pass, $total, $note) -ForegroundColor Green
} else {
    Write-Host ("SYNC VERIFIED: {0}/{1}   ({2} failed)" -f $script:Pass, $total, $script:Fail) -ForegroundColor Yellow
}
Write-Host "----------------------------------------------------------------"
# Exit on real failures only. A skipped criterion is a known, documented gap,
# not a broken run - if it set the exit code, sync-verify.cmd would print
# "SYNC VERIFICATION FAILED" underneath a green 9/10.
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
