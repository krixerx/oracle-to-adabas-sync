# Writes batch_info.dat (+ _COMPLETE) into an inbox batch directory.
#
# The pump does this automatically; this script exists so the stages can be
# run BY HAND while learning the pipeline (see TESTING_GUIDE_POC2.md §2).
#
# batch_info.dat carries the batch number and end SCN to the applier. It is
# generated here rather than by Hop because it is metadata ABOUT the batch,
# not a mapped data row - Hop has no row to hang it on.
#
# Usage:  scripts\make-batch-info.ps1 batch-000001
param(
    [Parameter(Mandatory = $true)][string]$Batch
)
$ErrorActionPreference = "Stop"
$poc = Split-Path -Parent $PSScriptRoot

$manifestPath = Join-Path $poc "sync\outbox\$Batch\manifest.json"
if (-not (Test-Path $manifestPath)) {
    throw "no manifest at $manifestPath (has the batch already been consumed?)"
}
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# Fixed-width: batch_no N6 + end_scn N15, both zero-padded (CHANGE_FILE_CONTRACT.md)
$line = ("{0:d6}{1}" -f [int]$manifest.batch, ([string]$manifest.end_scn).PadLeft(15, '0'))

$dir = Join-Path $poc "sync\inbox\$Batch"
New-Item -ItemType Directory -Force $dir | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $dir "batch_info.dat"), "$line`n", $utf8NoBom)

# _COMPLETE LAST - it is the commit point of the file protocol, and the
# applier refuses any batch directory without it.
[System.IO.File]::WriteAllText((Join-Path $dir "_COMPLETE"), "", $utf8NoBom)

Write-Host "wrote $dir\batch_info.dat  ->  $line"
Write-Host "wrote $dir\_COMPLETE       (batch is now readable)"
