# Lab data preparation for the Adabas source - NOT part of the migration.
#
# The Community Edition demo database gives us a VEHICLES file with no VIN and no
# vehicle-type field, and no traffic-fine file at all. Everything this lab is
# about therefore has to be manufactured in Adabas first:
#
#   1. fields BA (VIN, A25), BB (VEH-TYPE, A8) and BC (FUEL-DESC, A20) added to
#      file 12 with ADADBM ADD_FIELDS - online, no unload/reload, nucleus stays up;
#   2. file 20 (TRAFFINE) created with ADAFDU - a traffic-fine file with a
#      multiple-value field (offence codes) and a periodic group (payments);
#   3. natural/SEEDVEH.NSP fills in the VIN and type codes and stores the
#      duplicate rows the multi-plate workaround would have produced;
#   4. natural/SEEDFIN.NSP raises fines against those plates.
#
# Every step is idempotent, and has to be - `docker compose down -v` throws the
# demo database away and recreates it clean. scripts\lab-up.ps1 calls this.
$ErrorActionPreference = "Stop"
$pocRoot = Split-Path $PSScriptRoot -Parent
$naturalDir = Join-Path $pocRoot "natural"

$running = docker ps --filter "name=o2a-adabas" --filter "status=running" --format "{{.Names}}"
if (-not $running) { Write-Error "o2a-adabas is not running - start the lab first (scripts\lab-up.ps1)."; exit 1 }

# ---- 1. fields on file 12 -------------------------------------------------
# ADADBM refuses a field that already exists, so check the FDT rather than
# swallowing the error - a real failure must still be visible. Each field is
# checked and added on its own, so a lab that already has BA/BB picks up BC
# without being rebuilt.
$newFields = @(
    @{ code = "BA"; def = "01,BA,25,A,NU"; label = "VIN (A25)" }
    @{ code = "BB"; def = "01,BB,8,A,NU";  label = "VEH-TYPE (A8)" }
    @{ code = "BC"; def = "01,BC,20,A,NU"; label = "FUEL-DESC (A20)" }
    # A registration is never deleted - it EXPIRES. The legacy file has no such
    # field (AJ is DATE-ACQ, acquisition, a different fact that must not be
    # repurposed), so the lab adds one. U8 numeric YYYYMMDD, matching AJ and the
    # traffic-fine dates; NU, so "no value" means the plate is still current.
    @{ code = "BD"; def = "01,BD,8,U,NU";   label = "PLATE-EXPIRY (U8, YYYYMMDD)" }
)

$fdt = docker exec o2a-adabas sh -lc "adarep db=1 fdt file=12" 2>&1
if ($LASTEXITCODE -ne 0) { Write-Host ($fdt -join "`n"); Write-Error "adarep failed"; exit 1 }

foreach ($f in $newFields) {
    if (($fdt | Select-String -Pattern ('^\s*1\s+I\s+{0}\s+I' -f $f.code)).Count -gt 0) {
        Write-Host ("  file 12 already has {0} - skipping." -f $f.code)
        continue
    }
    Write-Host ("  adding {0} to Adabas file 12 ..." -f $f.label)
    # Field definitions are ADADBM *parameter lines*, terminated by END_OF_FIELDS;
    # there is no field= keyword despite ADADBM accepting one (that path wants a
    # different syntax and only ever answers FDUSYN). NU, no DE: a descriptor on a
    # loaded file would need an ADAINV pass, and nothing here searches by VIN.
    #
    # Fed through a heredoc INSIDE the container, not by piping into `docker exec -i`:
    # piped from PowerShell, adadbm silently reads nothing at all - it prints its
    # banner, never opens the database, and exits 0. A no-op that looks like success
    # is exactly what the output check below exists to catch.
    #
    # Joined with an explicit LF rather than written as a here-string: .gitattributes
    # checks .ps1 out with CRLF, a here-string would carry those CRs into the
    # container, and the heredoc body would reach adadbm as "db=1\r".
    $script = (@(
        "adadbm <<'ADABAS_EOF'"
        "db=1"
        "add_fields=12"
        $f.def
        "end_of_fields"
        "ADABAS_EOF"
    ) -join "`n")
    $out = docker exec o2a-adabas sh -c $script
    if ($LASTEXITCODE -ne 0 -or ($out -join "`n") -notmatch 'FUNC, function ADD_FIELDS executed') {
        Write-Host ($out -join "`n")
        Write-Error ("ADADBM ADD_FIELDS failed for {0}" -f $f.code)
        exit 1
    }
    Write-Host "    ADADBM ADD_FIELDS executed."
}

# ---- 2. the traffic-fine file -------------------------------------------
# The adabas service bind-mounts nothing from this repo (only natural does), so
# the FDT, the ADAFDU parameters and the script itself have to be copied in.
Write-Host "  creating Adabas file 20 (TRAFFINE) if it does not exist ..."
foreach ($f in @("TRAFFINE.fdt", "TRAFFINE.fdu", "create-fine-file.sh")) {
    docker cp (Join-Path $naturalDir $f) "o2a-adabas:/tmp/$f" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "docker cp $f failed"; exit 1 }
}
$out = docker exec o2a-adabas sh /tmp/create-fine-file.sh
if ($LASTEXITCODE -ne 0) { Write-Host ($out -join "`n"); Write-Error "ADAFDU failed"; exit 1 }
$out | Where-Object { $_ -match 'LOADED|already exists' } | ForEach-Object { Write-Host "    $_" }

# ---- 3 + 4. the data ----------------------------------------------------
Write-Host "  seeding vehicles (VIN / plates / types) and traffic fines ..."
$out = docker exec o2a-natural sh /poc/natural/run-seed.sh
if ($LASTEXITCODE -ne 0) {
    Write-Host ($out -join "`n")
    Write-Error "seed programs failed - see output above."
    exit 1
}
$out | ForEach-Object { Write-Host "    $_" }
exit 0
