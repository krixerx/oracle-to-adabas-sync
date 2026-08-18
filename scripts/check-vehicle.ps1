# Shows one vehicle as ORACLE has it and as ADABAS has it, side by side,
# and says whether the two agree on the synced fields.
#
# READ-ONLY. This does not synchronise anything - the sync is capture +
# sync-pump.ps1 (start both with sync-start.cmd). This only looks.
#
# The Adabas side is read by a SEPARATE Natural program (DUMPVEH), never by
# the sync's own bookkeeping - so agreement here means the data genuinely
# matches, not that the pipeline agrees with itself.
#
# ⚠️ A vehicle is a SET of Adabas records: file 12 holds ONE RECORD PER PLATE,
# the same car re-registered under a suffixed VIN. So the vehicle's own
# attributes are compared against EVERY record (they must all agree), and the
# plates are matched by plate number rather than by position - the dump comes
# back in ISN order, which need not be plate_seq order.
param(
    [Parameter(Mandatory = $true)][string]$Vin
)
$ErrorActionPreference = "Stop"
$poc = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------- Oracle
$sql = @"
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF LINESIZE 400
SELECT 'COLOR='   || color               FROM pocapp.vehicle WHERE vin = '$Vin';
SELECT 'MAKE='    || make                FROM pocapp.vehicle WHERE vin = '$Vin';
SELECT 'MODEL='   || model               FROM pocapp.vehicle WHERE vin = '$Vin';
SELECT 'VEHTYPE=' || source_vehicle_type FROM pocapp.vehicle WHERE vin = '$Vin';
SELECT 'STDTYPE=' || vehicle_type_code   FROM pocapp.vehicle WHERE vin = '$Vin';
SELECT 'OWNER='   || owner_national_id   FROM pocapp.vehicle WHERE vin = '$Vin';
SELECT 'NPLATES=' || COUNT(*) FROM pocapp.vehicle_plate
 WHERE vehicle_id = (SELECT vehicle_id FROM pocapp.vehicle WHERE vin = '$Vin');
SELECT 'PLATE|' || p.plate_no || '|' || NVL(TO_CHAR(p.expiry_date,'YYYYMMDD'),'0')
  FROM pocapp.vehicle_plate p
 WHERE p.vehicle_id = (SELECT vehicle_id FROM pocapp.vehicle WHERE vin = '$Vin')
 ORDER BY p.plate_seq;
EXIT;
"@
$tmp = Join-Path $env:TEMP "check_veh.sql"
[System.IO.File]::WriteAllText($tmp, $sql, (New-Object System.Text.UTF8Encoding($false)))
docker cp $tmp "o2a-oracle:/tmp/check_veh.sql" | Out-Null
$oraRaw = docker exec o2a-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1 `@/tmp/check_veh.sql 2>&1

$ora = @{}
$oraPlates = @{}      # plate number -> expiry (YYYYMMDD, or 0 when current)
foreach ($line in $oraRaw) {
    $l = "$line".Trim()
    if ($l -match '^PLATE\|([^|]*)\|(.*)$') { $oraPlates[$Matches[1].Trim()] = $Matches[2].Trim() }
    elseif ($l -match '^([A-Z]+)=(.*)$')    { $ora[$Matches[1]] = $Matches[2].Trim() }
}

# ---------------------------------------------------------------- Adabas
$adaRaw = docker exec o2a-natural sh /poc/natural/run-dump-veh.sh $Vin 2>&1
$ada = @{}
foreach ($line in $adaRaw) {
    $l = ("$line" -replace "`e\[[0-9;]*[a-zA-Z]", "").Trim()
    if ($l -match '^([A-Z0-9]+)=(.*)$') { $ada[$Matches[1]] = $Matches[2].Trim() }
}
$n = 0
if ($ada['NPLATES']) { $n = [int]$ada['NPLATES'] }

$adaPlates = @{}
for ($i = 1; $i -le $n; $i++) {
    $p = $ada["PLATE$i"]
    if ($p) { $adaPlates[$p] = $ada["EXPIRY$i"] }
}

# ---------------------------------------------------------------- report
Write-Host ""
Write-Host "  Vehicle $Vin" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------------------------"
if ($n -eq 0) {
    Write-Host "  (no such vehicle in Adabas)" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

Write-Host ("  {0,-12} {1,-24} {2,-24}" -f "FIELD", "ORACLE (source)", "ADABAS (target)")
Write-Host "  ---------------------------------------------------------------"

$mismatch = 0
# The vehicle's own attributes are repeated on every Adabas record, so each is
# compared against ALL of them: one record left behind is the failure mode this
# leg exists to prevent.
$attrs = @(
    @{ f = "COLOUR";   o = $ora['COLOR'];   a = "COLOR" }
    @{ f = "MAKE";     o = $ora['MAKE'];    a = "MAKE" }
    @{ f = "MODEL";    o = $ora['MODEL'];   a = "MODEL" }
    @{ f = "VEH TYPE"; o = $ora['VEHTYPE']; a = "VEHTYPE" }
    @{ f = "OWNER";    o = $ora['OWNER'];   a = "OWNER" }
)
foreach ($r in $attrs) {
    $o = if ($null -eq $r.o) { "" } else { $r.o }
    $vals = @(); for ($i = 1; $i -le $n; $i++) { $vals += [string]$ada["$($r.a)$i"] }
    $shown = ($vals | Select-Object -Unique) -join " / "
    $same  = ($vals.Count -gt 0) -and (($vals | Where-Object { $_ -ne $o }).Count -eq 0)
    if (-not $same) { $mismatch++ }
    Write-Host ("  {0,-12} {1,-24} {2,-24} {3}" -f $r.f, $o, $shown, $(if ($same) { "OK (x$n)" } else { "DIFFERS" })) `
        -ForegroundColor $(if ($same) { "Green" } else { "Yellow" })
}

$oPlates = $oraPlates.Count
$same = ($oPlates -eq $n)
if (-not $same) { $mismatch++ }
Write-Host ("  {0,-12} {1,-24} {2,-24} {3}" -f "#PLATES", $oPlates, $n, $(if ($same) { "OK" } else { "DIFFERS" })) `
    -ForegroundColor $(if ($same) { "Green" } else { "Yellow" })

Write-Host "  ---------------------------------------------------------------"
Write-Host "  Registrations (0 = still current, otherwise the expiry date)"
foreach ($plate in ($oraPlates.Keys | Sort-Object)) {
    $oExp = $oraPlates[$plate]
    if ($adaPlates.ContainsKey($plate)) {
        $aExp = $adaPlates[$plate]
        $ok = ($oExp -eq $aExp)
        if (-not $ok) { $mismatch++ }
        Write-Host ("  {0,-12} expires {1,-16} expires {2,-16} {3}" -f $plate, $oExp, $aExp, $(if ($ok) { "OK" } else { "DIFFERS" })) `
            -ForegroundColor $(if ($ok) { "Green" } else { "Yellow" })
    } else {
        $mismatch++
        Write-Host ("  {0,-12} expires {1,-16} {2}" -f $plate, $oExp, "NOT IN ADABAS") -ForegroundColor Yellow
    }
}
foreach ($plate in ($adaPlates.Keys | Sort-Object)) {
    if (-not $oraPlates.ContainsKey($plate)) {
        # Not counted as a mismatch: under the no-delete rule an Adabas record
        # that Oracle no longer lists is history, not drift.
        Write-Host ("  {0,-12} {1,-24} only in Adabas (never deleted)" -f $plate, "-") -ForegroundColor DarkGray
    }
}

Write-Host "  ---------------------------------------------------------------"
if ($mismatch -eq 0) {
    Write-Host "  IN SYNC" -ForegroundColor Green
} else {
    Write-Host "  NOT IN SYNC ($mismatch difference(s))" -ForegroundColor Yellow
    Write-Host "  If you just made the change, wait ~10 s and run this again." -ForegroundColor DarkGray
    Write-Host "  Still differing? Check the O2A CAPTURE and O2A PUMP windows." -ForegroundColor DarkGray
}
Write-Host ""

# Explicit: this is a REPORT, not a test. Leaving the exit code to whatever the
# last docker call happened to return made a green "IN SYNC" exit 255.
exit 0
