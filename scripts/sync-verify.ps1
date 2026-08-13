# Sync acceptance harness: the ten success criteria from the spec (§7).
# Prints "SYNC VERIFIED: n/n", in the spirit of the migration lab's "VERIFIED: 5/5".
#
# Each test makes a change in ORACLE, runs the sync, and asserts on ADABAS.
# Assertions read Adabas through DUMPEMP - never through the sync's own
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

$TESTKEY = '11100102'      # existing employee, has MU + PE data
$NEWKEY  = 'ZZ777702'      # synthetic, created and removed by test 2/3

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
    # Give the flush timer (5 s) time to write a batch, then pump it through.
    Start-Sleep -Seconds $waitSeconds
    $out = powershell -File (Join-Path $poc "scripts\sync-pump.ps1") 2>&1
    return ($out -join "`n")
}

function Reset-Ledger {
    docker exec o2a-natural sh /poc/natural/run-reset-ledger.sh 2>&1 | Out-Null
}

function Clear-SyncDirs {
    foreach ($d in @('applied', 'inbox', 'outbox', 'rejected')) {
        $p = Join-Path $poc "sync\$d"
        if (Test-Path $p) {
            Get-ChildItem $p -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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
Sql @"
UPDATE pocapp.employee SET city='BASELINE', job_title='BASELINE JOB'
 WHERE personnel_id='$TESTKEY';
DELETE FROM pocapp.employee_language
 WHERE emp_id=(SELECT emp_id FROM pocapp.employee WHERE personnel_id='$TESTKEY')
   AND seq_no > 1;
DELETE FROM pocapp.employee WHERE personnel_id='$NEWKEY';
COMMIT;
"@ | Out-Null

$cap = Start-Capture 300
try {
    Sync-Once | Out-Null      # drain the baseline change so tests start clean

    # -------------------------------------------------------------- 1
    Sql "UPDATE pocapp.employee SET city='T1-VILNIUS' WHERE personnel_id='$TESTKEY'; COMMIT;" | Out-Null
    Sync-Once | Out-Null
    $d = Dump $TESTKEY
    Check 1 "scalar update propagates" ($d['CITY'] -eq 'T1-VILNIUS') "CITY=$($d['CITY'])"

    # -------------------------------------------------------------- 2
    Sql @"
INSERT INTO pocapp.employee (source_isn, personnel_id, first_name, last_name,
       birth_date, gender_code, marital_status, dept_code, job_title, city,
       postal_code, country_code)
VALUES (999702, '$NEWKEY', 'NEW', 'VIAORACLE', DATE '1991-02-03', 'F',
        'Married', 'IT', 'ANALYST', 'RIGA', '1010', 'LVA');
INSERT INTO pocapp.employee_language (emp_id, seq_no, language_code)
 SELECT emp_id, 1, 'LAV' FROM pocapp.employee WHERE personnel_id='$NEWKEY';
COMMIT;
"@ | Out-Null
    Sync-Once | Out-Null
    $d = Dump $NEWKEY
    # marital_status 'Married' must come back as the CODE 'M' - proving the
    # reverse CODE_LOOKUP ran, not just that a row arrived.
    Check 2 "insert propagates (incl. reverse code lookup)" `
        ($d['FOUND'] -and $d['CITY'] -eq 'RIGA' -and $d['MARSTAT'] -eq 'M') `
        "FOUND=$($d['FOUND']) CITY=$($d['CITY']) MARSTAT=$($d['MARSTAT'])"

    # -------------------------------------------------------------- 3
    Sql "DELETE FROM pocapp.employee_language WHERE emp_id=(SELECT emp_id FROM pocapp.employee WHERE personnel_id='$NEWKEY'); DELETE FROM pocapp.employee WHERE personnel_id='$NEWKEY'; COMMIT;" | Out-Null
    Sync-Once | Out-Null
    $d = Dump $NEWKEY
    Check 3 "delete propagates" ($d['NOTFOUND'] -eq $true) "record still present"

    # -------------------------------------------------------------- 4
    # The MU/PE case that silently corrupts if the applier forgets to RESET
    # trailing occurrences before lowering the count.
    Sql @"
INSERT INTO pocapp.employee_language (emp_id, seq_no, language_code)
 SELECT emp_id, 50, 'SWE' FROM pocapp.employee WHERE personnel_id='$TESTKEY';
INSERT INTO pocapp.employee_language (emp_id, seq_no, language_code)
 SELECT emp_id, 60, 'NOR' FROM pocapp.employee WHERE personnel_id='$TESTKEY';
COMMIT;
"@ | Out-Null
    Sync-Once | Out-Null
    $grow = Dump $TESTKEY
    $grewOk = ($grow['CLANG'] -eq '3' -and $grow['LANG2'] -eq 'SWE' -and $grow['LANG3'] -eq 'NOR')

    Sql "DELETE FROM pocapp.employee_language WHERE emp_id=(SELECT emp_id FROM pocapp.employee WHERE personnel_id='$TESTKEY') AND seq_no >= 50; COMMIT;" | Out-Null
    Sync-Once | Out-Null
    $shrink = Dump $TESTKEY
    # Assert the residue is GONE, not merely uncounted: LANG2/LANG3 are read
    # beyond the count deliberately.
    $shrankOk = ($shrink['CLANG'] -eq '1' -and $shrink['LANG2'] -eq '' -and $shrink['LANG3'] -eq '')
    Check 4 "MU set grows and shrinks, no residue" ($grewOk -and $shrankOk) `
        "grow CLANG=$($grow['CLANG']) LANG2=$($grow['LANG2']); shrink CLANG=$($shrink['CLANG']) LANG2='$($shrink['LANG2'])' LANG3='$($shrink['LANG3'])'"

    # -------------------------------------------------------------- 5
    Sql @"
UPDATE pocapp.employee SET city='T5-CITY', job_title='T5 JOB' WHERE personnel_id='$TESTKEY';
INSERT INTO pocapp.employee_language (emp_id, seq_no, language_code)
 SELECT emp_id, 70, 'DAN' FROM pocapp.employee WHERE personnel_id='$TESTKEY';
COMMIT;
"@ | Out-Null
    Sync-Once | Out-Null
    $d = Dump $TESTKEY
    Check 5 "multi-table transaction lands together" `
        ($d['CITY'] -eq 'T5-CITY' -and $d['JOB'] -eq 'T5 JOB' -and $d['CLANG'] -eq '2' -and $d['LANG2'] -eq 'DAN') `
        "CITY=$($d['CITY']) JOB=$($d['JOB']) CLANG=$($d['CLANG']) LANG2=$($d['LANG2'])"

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
    Sql "UPDATE pocapp.employee SET city='ECHO-CITY' WHERE personnel_id='$TESTKEY'; COMMIT;" "syncapp/syncapp" | Out-Null
    Sync-Once | Out-Null
    $after = Dump $TESTKEY
    $capLog = Get-Content (Join-Path $poc "sync\capture.log") -Raw -ErrorAction SilentlyContinue
    Check 7 "SYNCAPP writes are filtered out" `
        ($after['CITY'] -eq $before['CITY'] -and $after['CITY'] -ne 'ECHO-CITY') `
        "Adabas CITY=$($after['CITY']) (expected unchanged $($before['CITY']))"
    # put Oracle back so later assertions are not confused by the echo row
    Sql "UPDATE pocapp.employee SET city='$($before['CITY'])' WHERE personnel_id='$TESTKEY'; COMMIT;" "syncapp/syncapp" | Out-Null

    # -------------------------------------------------------------- 8
    # Crash mid-batch: apply a batch, kill nothing, but simulate the crash
    # window by re-applying an un-acknowledged batch. Nothing may double.
    Sql "UPDATE pocapp.employee SET job_title='T8 CRASHTEST' WHERE personnel_id='$TESTKEY'; COMMIT;" | Out-Null
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
            ($d['JOB'] -eq 'T8 CRASHTEST' -and $flat -match "ALREADY-APPLIED|NOOP-IDENTICAL") `
            "JOB=$($d['JOB']); re-apply said: $(($flat -replace '\s+',' ').Trim())"
        Move-Item $dir (Join-Path $poc "sync\applied\$($ready.Name)") -Force
        Remove-Item -Recurse -Force $ready.FullName
    } else {
        Check 8 "crash mid-batch: re-apply is clean" $false "no batch was produced"
    }

    # -------------------------------------------------------------- 9
    # Adabas outage: stop the nucleus, make changes, restart, drain.
    Write-Host "        (stopping Adabas for the outage test...)" -ForegroundColor DarkGray
    docker compose stop adabas | Out-Null
    Sql "UPDATE pocapp.employee SET city='T9-OUTAGE-1' WHERE personnel_id='$TESTKEY'; COMMIT;" | Out-Null
    Start-Sleep -Seconds 3
    Sql "UPDATE pocapp.employee SET city='T9-OUTAGE-2' WHERE personnel_id='$TESTKEY'; COMMIT;" | Out-Null
    Start-Sleep -Seconds 12
    $queued = (Get-ChildItem (Join-Path $poc "sync\outbox") -Directory -ErrorAction SilentlyContinue).Count
    powershell -File (Join-Path $poc "scripts\lab-up.ps1") | Out-Null
    Start-Sleep -Seconds 5
    Sync-Once 3 | Out-Null
    $d = Dump $TESTKEY
    Check 9 "Adabas outage: changes queue and drain" `
        ($queued -ge 1 -and $d['CITY'] -eq 'T9-OUTAGE-2') `
        "queued=$queued CITY=$($d['CITY'])"

    # -------------------------------------------------------------- 10
    # Conflict detection is a documented stretch goal (spec 5.4): the
    # before-image is available for free thanks to ALL COLUMNS supplemental
    # logging, but the applier does not yet compare against it.
    Skip 10 "conflict detected and routed to rejected/" `
        "out of scope this round (spec 5.4) - the before-image is already free from ALL COLUMNS supplemental logging, but the applier does not compare against it yet"

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
