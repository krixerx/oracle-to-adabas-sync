# One-time Adabas setup for the sync: creates file 99 (SYNCLEDGER), the
# apply watermark file.
#
# WHY THIS EXISTS: the applier (natural/APPLYFIN.NSP) writes a ledger record in
# the SAME Adabas ET as the data change, so a crash between "applied" and
# "recorded as applied" is impossible. That watermark also drives the ordering
# guard, which refuses any batch not strictly newer than the last one applied.
# Without file 99 the applier has nowhere to write it and every batch fails.
#
# The Adabas CE image ships the demo database files but of course
# knows nothing about file 99, so a fresh adabas-data volume needs this run
# once. It is idempotent: re-running it on an existing file 99 is a no-op.
#
# Run it AFTER scripts\lab-up.ps1 (the container must exist) and alongside
# scripts\setup-cdc.ps1, which does the equivalent one-time job on Oracle.

$ErrorActionPreference = "Stop"
$poc = Split-Path -Parent $PSScriptRoot
$container = "o2a-adabas"

$running = docker ps --filter "name=$container" --filter "status=running" --format "{{.Names}}"
if (-not $running) {
    throw "$container is not running. Run scripts\lab-up.ps1 first."
}

Write-Host "== creating Adabas file 99 (SYNCLEDGER) ==" -ForegroundColor Cyan

# The adabas service does not bind-mount the repo, so copy the inputs in.
$sources = @(
    (Join-Path $poc "natural\LEDGER.fdt"),
    (Join-Path $poc "natural\LEDGER.fdu"),
    (Join-Path $poc "scripts\create-ledger.sh")
)
foreach ($local in $sources) {
    if (-not (Test-Path $local)) { throw "missing $local" }
    docker cp $local "${container}:/tmp/$(Split-Path -Leaf $local)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker cp failed for $local" }
}

# Run it through `sh` rather than executing it directly: a docker-cp'd file
# lands owned by root, the Adabas image runs as a non-root user, and chmod on
# someone else's file fails with "Operation not permitted".
docker exec $container sh /tmp/create-ledger.sh
if ($LASTEXITCODE -ne 0) { throw "create-ledger.sh failed" }

Write-Host ""
Write-Host "Adabas file 99 ready." -ForegroundColor Green
