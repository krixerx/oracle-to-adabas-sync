# Shows one employee as ORACLE has it and as ADABAS has it, side by side,
# and says whether the two agree on the synced fields.
#
# The Adabas side is read by a SEPARATE Natural program (DUMPEMP), never by
# the sync's own bookkeeping - so agreement here means the data genuinely
# matches, not that the pipeline agrees with itself.
param(
    [Parameter(Mandatory = $true)][string]$PersonnelId
)
$ErrorActionPreference = "Stop"
$poc = Split-Path -Parent $PSScriptRoot

# ---------------------------------------------------------------- Oracle
$sql = @"
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF LINESIZE 400
SELECT 'CITY='     || city         FROM pocapp.employee WHERE personnel_id = '$PersonnelId';
SELECT 'JOB='      || job_title    FROM pocapp.employee WHERE personnel_id = '$PersonnelId';
SELECT 'LASTNAME=' || last_name    FROM pocapp.employee WHERE personnel_id = '$PersonnelId';
SELECT 'MARSTAT='  || marital_status FROM pocapp.employee WHERE personnel_id = '$PersonnelId';
SELECT 'NLANG='    || COUNT(*) FROM pocapp.employee_language
 WHERE emp_id = (SELECT emp_id FROM pocapp.employee WHERE personnel_id = '$PersonnelId');
EXIT;
"@
$tmp = Join-Path $env:TEMP "check_emp.sql"
[System.IO.File]::WriteAllText($tmp, $sql, (New-Object System.Text.UTF8Encoding($false)))
docker cp $tmp "o2a-oracle:/tmp/check_emp.sql" | Out-Null
$oraRaw = docker exec o2a-oracle sqlplus -s pocapp/pocapp@//localhost:1521/FREEPDB1 `@/tmp/check_emp.sql 2>&1

$ora = @{}
foreach ($line in $oraRaw) {
    if ("$line" -match '^([A-Z]+)=(.*)$') { $ora[$Matches[1]] = $Matches[2].Trim() }
}

# ---------------------------------------------------------------- Adabas
$adaRaw = docker exec o2a-natural sh /poc/natural/run-dump.sh $PersonnelId 2>&1
$ada = @{}
$notFound = $false
foreach ($line in $adaRaw) {
    $l = ("$line" -replace "`e\[[0-9;]*[a-zA-Z]", "").Trim()
    if ($l -match '^NOTFOUND') { $notFound = $true }
    if ($l -match '^([A-Z0-9]+)=(.*)$') { $ada[$Matches[1]] = $Matches[2].Trim() }
}

# ---------------------------------------------------------------- report
Write-Host ""
Write-Host "  Employee $PersonnelId" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------------------------"
Write-Host ("  {0,-12} {1,-24} {2,-24} {3}" -f "FIELD", "ORACLE (source)", "ADABAS (target)", "")
Write-Host "  ---------------------------------------------------------------"

if ($notFound) {
    Write-Host "  (no such record in Adabas)" -ForegroundColor Yellow
}

# marital_status is stored as the DESCRIPTION in Oracle and as the CODE in
# Adabas, so they are compared by first letter - that difference IS the
# mapping, not a mismatch.
$rows = @(
    @{ f = "CITY";     o = $ora['CITY'];     a = $ada['CITY'];  exact = $true }
    @{ f = "JOB TITLE"; o = $ora['JOB'];     a = $ada['JOB'];   exact = $true }
    @{ f = "LAST NAME"; o = $ora['LASTNAME']; a = $ada['NAME']; exact = $true }
    @{ f = "MARITAL";  o = $ora['MARSTAT'];  a = $ada['MARSTAT']; exact = $false }
    @{ f = "#LANGUAGES"; o = $ora['NLANG'];  a = $ada['CLANG']; exact = $true }
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
