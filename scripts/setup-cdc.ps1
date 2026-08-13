# One-time Oracle setup for change capture (spec C1, gating spike S1).
#
# Idempotent - safe to re-run. Applies to an EXISTING lab volume, which is
# how a database created before the sync gets the CDC prerequisites; a lab
# built from an empty volume picks up 03_cdc_setup.sql automatically via
# /container-entrypoint-initdb.d, but still needs the ARCHIVELOG step here
# (it requires MOUNT state, so it cannot be an init hook).
#
# Usage:  powershell -File scripts\setup-cdc.ps1
$ErrorActionPreference = "Stop"
$poc = Split-Path -Parent $PSScriptRoot

function Invoke-InOracle([string]$LocalPath, [string]$RemotePath, [string]$Command) {
    docker cp $LocalPath "o2a-oracle:$RemotePath" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker cp failed for $LocalPath" }
    docker exec -e ORACLE_SID=FREE o2a-oracle bash -lc $Command
    if ($LASTEXITCODE -ne 0) { throw "failed: $Command" }
}

Write-Host "== 1/3  users, grants, supplemental logging =="
Invoke-InOracle "$poc\oracle-init\03_cdc_setup.sql" "/tmp/03_cdc_setup.sql" `
    'echo exit | sqlplus -s / as sysdba @/tmp/03_cdc_setup.sql'

Write-Host "`n== 2/3  ARCHIVELOG mode + archive destination =="
Invoke-InOracle "$poc\scripts\enable-archivelog.sh" "/tmp/enable-archivelog.sh" `
    'sh /tmp/enable-archivelog.sh'

Write-Host "`n== 3/3  install the purge job =="
docker cp "$poc\scripts\purge-archivelogs.sh" "o2a-oracle:/tmp/purge-archivelogs.sh" | Out-Null
Write-Host "  installed at /tmp/purge-archivelogs.sh"
Write-Host "  run periodically:  docker exec -e ORACLE_SID=FREE o2a-oracle sh /tmp/purge-archivelogs.sh 24"
Write-Host "  ARCHIVELOG without a purge job fills the disk in days."

Write-Host "`n== verification =="
$verify = @'
SET LINESIZE 200 PAGESIZE 100 FEEDBACK OFF
SELECT log_mode, open_mode, supplemental_log_data_min AS min_sup,
       supplemental_log_data_pk AS pk_sup FROM v$database;
SELECT COUNT(*) AS capture_user FROM cdb_users WHERE username = 'C##DBZUSER';
ALTER SESSION SET CONTAINER = FREEPDB1;
SET LINESIZE 200 PAGESIZE 100 FEEDBACK OFF
SELECT COUNT(*) AS tables_all_col_logging FROM dba_log_groups
 WHERE owner = 'POCAPP' AND log_group_type = 'ALL COLUMN LOGGING';
SELECT COUNT(*) AS apply_back_user FROM dba_users WHERE username = 'SYNCAPP';
EXIT;
'@
# Write the script to a file and run it with @ rather than piping it in:
# PowerShell prefixes piped text with a UTF-8 BOM, and sqlplus then reports
# SP2-0734 and DISCARDS THE FIRST LINE. Harmless when line 1 is a SET, silently
# destructive when it is a statement that matters.
$verifyFile = Join-Path $env:TEMP "poc2_verify.sql"
[System.IO.File]::WriteAllText($verifyFile, $verify, (New-Object System.Text.UTF8Encoding($false)))
docker cp $verifyFile "o2a-oracle:/tmp/poc2_verify.sql" | Out-Null
docker exec -e ORACLE_SID=FREE o2a-oracle bash -lc 'echo exit | sqlplus -s / as sysdba @/tmp/poc2_verify.sql'

Write-Host "`nCDC setup complete."
