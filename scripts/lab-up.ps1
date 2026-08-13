# Brings the POC lab up, clearing the stale Adabas concurrency lock first.
#
# WHY: the Adabas nucleus writes /data/db001/_DB_LOCK holding "<pid>;<hostname>;"
# and removes it on a clean shutdown. If the container dies without one - Docker
# Desktop stopping underneath it, a host reboot, `docker kill` - the lock stays
# in the data VOLUME and every later start aborts with:
#     %ADANUC-F-CONCURRLOCKPID, Concurrency lock found for pid <n>
# and the container exits 0, which reads like a successful start until you look.
# (compose already pins `hostname:` to avoid the sibling CONCURRLOCKHOST case.)
#
# Clearing the lock is safe ONLY when no nucleus is running - which is exactly
# the situation here, since the container is down. The script therefore refuses
# to touch it while o2a-adabas is up.
$ErrorActionPreference = "Stop"
$poc = Split-Path -Parent $PSScriptRoot
$volume = "o2a_adabas-data"
$image  = "softwareag/adabas-ce:7.4.0"

$running = docker ps --filter "name=o2a-adabas" --filter "status=running" --format "{{.Names}}"
if ($running) {
    Write-Host "o2a-adabas is running; leaving the lock alone."
} else {
    $lock = docker run --rm --entrypoint sh -v "${volume}:/data" $image `
        -c "cat /data/db001/_DB_LOCK 2>/dev/null" 2>$null
    if ($lock) {
        Write-Host "stale Adabas lock found: $lock  -> removing"
        docker run --rm --entrypoint sh -v "${volume}:/data" $image `
            -c "rm -f /data/db001/_DB_LOCK" | Out-Null
    }
}

Push-Location $poc
try {
    docker compose up -d --wait
    if ($LASTEXITCODE -ne 0) { throw "docker compose up failed" }
} finally {
    Pop-Location
}

docker ps --filter "name=o2a" --format "table {{.Names}}\t{{.Status}}"

# A clean nucleus start ends with DBSTART. Its absence means the nucleus aborted
# even though the container may look alive.
$nuc = docker logs --since 5m o2a-adabas 2>&1 | Select-String "DBSTART|CONCURRLOCK|ABORTED"
if ($nuc) { Write-Host "`nAdabas nucleus:"; $nuc | ForEach-Object { Write-Host "  $_" } }
