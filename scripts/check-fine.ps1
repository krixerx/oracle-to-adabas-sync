# Shows one traffic fine as ORACLE has it and as ADABAS has it, side by side,
# and says whether the two agree on the synced fields.
#
# The Adabas side is read by a SEPARATE Natural program (DUMPFIN), never by
# the sync's own bookkeeping - so agreement here means the data genuinely
# matches, not that the pipeline agrees with itself.
param(
    [Parameter(Mandatory = $true)][string]$FineNo
)
$ErrorActionPreference = "Stop"
$poc = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------- Oracle
$sql = @"
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF LINESIZE 400
SELECT 'LOC='      || location   FROM pocapp.traffic_fine WHERE fine_no = '$FineNo';
SELECT 'PLATE='    || plate_no   FROM pocapp.traffic_fine WHERE fine_no = '$FineNo';
SELECT 'AMOUNT='   || TO_CHAR(amount,'FM99999990.00') FROM pocapp.traffic_fine WHERE fine_no = '$FineNo';
SELECT 'STATUS='   || status     FROM pocapp.traffic_fine WHERE fine_no = '$FineNo';
SELECT 'NOFF='     || COUNT(*) FROM pocapp.traffic_fine_offence
 WHERE fine_id = (SELECT fine_id FROM pocapp.traffic_fine WHERE fine_no = '$FineNo');
SELECT 'NPAY='     || COUNT(*) FROM pocapp.traffic_fine_payment
 WHERE fine_id = (SELECT fine_id FROM pocapp.traffic_fine WHERE fine_no = '$FineNo');
EXIT;
"@
$tmp = Join-Path $env:TEMP "check_fine.sql"
[System.IO.File]::WriteAllText($tmp, $sql, (New-Object System.Text.UTF8Encoding($false)))
docker cp $tmp "o2a-oracle:/tmp/check_fine.sql" | Out-Null
$oraRaw = docker exec o2a-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1 `@/tmp/check_fine.sql 2>&1

$ora = @{}
foreach ($line in $oraRaw) {
    if ("$line" -match '^([A-Z]+)=(.*)$') { $ora[$Matches[1]] = $Matches[2].Trim() }
}

# ---------------------------------------------------------------- Adabas
$adaRaw = docker exec o2a-natural sh /poc/natural/run-dump.sh $FineNo 2>&1
$ada = @{}
$notFound = $false
foreach ($line in $adaRaw) {
    $l = ("$line" -replace "`e\[[0-9;]*[a-zA-Z]", "").Trim()
    if ($l -match '^NOTFOUND') { $notFound = $true }
    if ($l -match '^([A-Z0-9]+)=(.*)$') { $ada[$Matches[1]] = $Matches[2].Trim() }
}

# ---------------------------------------------------------------- report
Write-Host ""
Write-Host "  Traffic fine $FineNo" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------------------------"
Write-Host ("  {0,-12} {1,-24} {2,-24} {3}" -f "FIELD", "ORACLE (source)", "ADABAS (target)", "")
Write-Host "  ---------------------------------------------------------------"

if ($notFound) {
    Write-Host "  (no such record in Adabas)" -ForegroundColor Yellow
}

# status is stored as the DESCRIPTION in Oracle and as the CODE in Adabas,
# so they are compared by first letter - that difference IS the mapping,
# not a mismatch. (It holds for this domain: Issued/Paid/Cancelled/Appealed
# all start with their own code letter.)
$rows = @(
    @{ f = "LOCATION"; o = $ora['LOC'];    a = $ada['LOC'];    exact = $true }
    @{ f = "PLATE";    o = $ora['PLATE'];  a = $ada['PLATE'];  exact = $true }
    @{ f = "AMOUNT";   o = $ora['AMOUNT']; a = $ada['AMOUNT']; exact = $true }
    @{ f = "STATUS";   o = $ora['STATUS']; a = $ada['STATUS']; exact = $false }
    @{ f = "#OFFENCES"; o = $ora['NOFF'];  a = $ada['COFF'];   exact = $true }
    @{ f = "#PAYMENTS"; o = $ora['NPAY'];  a = $ada['CPAY'];   exact = $true }
)

$mismatch = 0
foreach ($r in $rows) {
    $o = if ($null -eq $r.o) { "" } else { $r.o }
    $a = if ($null -eq $r.a) { "" } else { $r.a }
    if ($r.exact) { $same = ($o -eq $a) }
    else          { $same = ($o.Length -gt 0 -and $a.Length -gt 0 -and $o.Substring(0,1) -eq $a) }
    if (-not $same) { $mismatch++ }
    $mark  = if ($same) { "OK" } else { "DIFFERS" }
    $color = if ($same) { "Green" } else { "Yellow" }
    Write-Host ("  {0,-12} {1,-24} {2,-24} {3}" -f $r.f, $o, $a, $mark) -ForegroundColor $color
}

Write-Host "  ---------------------------------------------------------------"
if ($mismatch -eq 0 -and -not $notFound) {
    Write-Host "  IN SYNC" -ForegroundColor Green
} else {
    Write-Host "  NOT IN SYNC ($mismatch field(s) differ)" -ForegroundColor Yellow
    Write-Host "  If you just made the change, wait ~10 s and run this again." -ForegroundColor DarkGray
    Write-Host "  Still differing? Check the O2A CAPTURE and O2A PUMP windows." -ForegroundColor DarkGray
}
Write-Host ""

# The full Adabas record, so MU/PE occurrences are visible too.
Write-Host "  Adabas record (raw dump, 6 occurrences shown regardless of count):" -ForegroundColor DarkGray
foreach ($line in $adaRaw) {
    $l = ("$line" -replace "`e\[[0-9;]*[a-zA-Z]", "").TrimEnd()
    if ($l.Trim()) { Write-Host "    $l" -ForegroundColor DarkGray }
}

# Explicit: this is a REPORT, not a test. Leaving the exit code to whatever
# the last docker call happened to return made a green "IN SYNC" exit 255.
exit 0
