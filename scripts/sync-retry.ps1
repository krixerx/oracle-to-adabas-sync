# Retry one batch that failed to apply.
#
#   sync-retry.ps1                    list what is waiting in sync/rejected
#   sync-retry.ps1 -Batch batch-000007
#   sync-retry.ps1 -Batch batch-000007 -Remap    map it again from the outbox first
#
# WHY RETRY IS SAFE, AND SKIP IS NOT.
#
# Retrying is safe by construction, not by luck. Three mechanisms make it a
# no-op when it is not needed: the Adabas ledger refuses any batch not newer
# than its watermark, compare-before-write means re-applying identical data
# changes nothing, and the pump halts rather than skipping, so nothing after
# the failed batch was ever applied.
#
# SKIP IS THE OPERATION THAT MUST NOT EXIST - at any effort level, behind any
# flag. Applying N+1 while N is unapplied moves the watermark past N, and N can
# then never be applied: a permanent, silent gap in the synchronised data. That
# is why this script refuses to touch a batch when an older one is still
# waiting, rather than trusting the operator to notice.
#
# It runs on the HOST because a container cannot rename a directory on a
# Windows bind mount - the same constraint that puts the acknowledgement in
# sync-pump.ps1 rather than in the applier.
param(
    [string]$Batch,
    [switch]$Remap
)
$ErrorActionPreference = "Stop"
$poc = Split-Path -Parent $PSScriptRoot
$outbox   = Join-Path $poc "sync\outbox"
$inbox    = Join-Path $poc "sync\inbox"
$applied  = Join-Path $poc "sync\applied"
$rejected = Join-Path $poc "sync\rejected"

function Get-BatchNumber([string]$name) {
    if ($name -match '^batch-(\d{6})$') { return [int]$Matches[1] }
    throw "not a batch directory name: $name"
}

function Show-Rejected {
    if (-not (Test-Path $rejected)) { Write-Host "nothing rejected."; return }
    $dirs = Get-ChildItem $rejected -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    if (-not $dirs) { Write-Host "nothing rejected."; return }
    Write-Host ""
    Write-Host "Batches waiting in sync/rejected:"
    foreach ($d in $dirs) {
        # The applier's own verdict travels with the batch (the pump writes it
        # in before the acknowledgement), so the reason is right here and no log
        # store has to be consulted.
        $reason = Get-ChildItem $d.FullName -Filter "apply_result*.txt" -ErrorAction SilentlyContinue |
            ForEach-Object { Select-String -Path $_.FullName -Pattern 'REFUSED-|REJECTED-' -ErrorAction SilentlyContinue } |
            Select-Object -First 1
        Write-Host ("  {0}   {1}" -f $d.Name, $(if ($reason) { $reason.Line.Trim() } else { "(see apply_result.txt)" }))
    }
    Write-Host ""
    Write-Host "Retry the OLDEST one first:  scripts\sync-retry.ps1 -Batch $($dirs[0].Name)"
}

if (-not $Batch) { Show-Rejected; exit 0 }

$n = Get-BatchNumber $Batch

# --- ordering guard --------------------------------------------------------
# Anything older than the requested batch, anywhere in the queue, means this
# retry would jump the queue. That is the skip this design must never perform.
$blocking = @()
foreach ($dir in @($rejected, $inbox, $outbox)) {
    if (-not (Test-Path $dir)) { continue }
    $blocking += Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^batch-\d{6}$' -and (Get-BatchNumber $_.Name) -lt $n } |
        ForEach-Object { "$($_.Name) in $(Split-Path $dir -Leaf)/" }
}
if ($blocking) {
    Write-Host "REFUSING: older batches are still unapplied -" -ForegroundColor Red
    $blocking | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Batches apply in order. Retrying this one now would move the ledger" -ForegroundColor Yellow
    Write-Host "watermark past them and they could NEVER be applied. Retry the oldest first."
    exit 1
}

if (Test-Path (Join-Path $applied $Batch)) {
    Write-Host "$Batch is already in applied/ - nothing to retry."
    exit 0
}

# --- put the batch back in the inbox ---------------------------------------
$target = Join-Path $inbox $Batch
$fromRejected = Join-Path $rejected $Batch
$fromOutbox   = Join-Path $outbox $Batch

if ($Remap -or -not (Test-Path $fromRejected)) {
    # Re-map from the captured CSV. Needed when the failure was in the mapping
    # stage (nothing ever reached the inbox), or when a Hop pipeline has been
    # fixed and the fixed-width files have to be regenerated.
    if (-not (Test-Path $fromOutbox)) {
        Write-Host "no $Batch in sync/outbox or sync/rejected - nothing to retry." -ForegroundColor Red
        exit 1
    }
    Write-Host "re-mapping $Batch through Hop Server..."
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    $url = "http://localhost:8081/hop/execWorkflow/?workflow=/poc/hop/workflows/sync-apply.hwf" +
           "&runConfig=local&level=Basic&BATCH_IN=/sync/outbox/$Batch&BATCH_OUT=/sync/inbox/$Batch"
    $resp = (curl.exe -s -u "cluster:cluster" --max-time 300 $url) -join "`n"
    if ($resp -notmatch "<result>OK</result>") {
        Write-Host "MAPPING FAILED - is Hop Server up? (docker compose --profile sync up -d hop-server)" -ForegroundColor Red
        Write-Host ($resp -replace "\s+", " ")
        exit 1
    }
    # batch_info.dat and _COMPLETE, exactly as the pump writes them.
    $manifest = Get-Content (Join-Path $fromOutbox "manifest.json") -Raw | ConvertFrom-Json
    $line = ("{0:d6}{1}" -f [int]$manifest.batch, ([string]$manifest.end_scn).PadLeft(15, '0'))
    New-Item -ItemType Directory -Force $target | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $target "batch_info.dat"), "$line`n",
        (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $target "_COMPLETE"), "",
        (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path $fromRejected) { Remove-Item -Recurse -Force $fromRejected }
} else {
    Write-Host "moving $Batch back from rejected/ to inbox/..."
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Move-Item $fromRejected $target
}

# --- apply -----------------------------------------------------------------
Write-Host "applying $Batch..."
$out = docker exec o2a-natural sh /poc/natural/run-apply.sh $Batch 2>&1
$ok = ($LASTEXITCODE -eq 0)     # read it before anything else clobbers it
$out | ForEach-Object { Write-Host "    $_" }
# Same as the pump: the verdict has to travel with the batch, and it has to be
# written from the host - see the comment on Save-ApplyResult in sync-pump.ps1.
$text = ($out | ForEach-Object { $_.ToString() }) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $target "apply_result.txt"), $text + "`n",
    (New-Object System.Text.UTF8Encoding($false)))

$dest = Join-Path $poc ("sync\" + $(if ($ok) { "applied" } else { "rejected" }))
New-Item -ItemType Directory -Force $dest | Out-Null
$final = Join-Path $dest $Batch
if (Test-Path $final) { Remove-Item -Recurse -Force $final }
Move-Item $target $final

if ($ok) {
    # The outbox copy has served its purpose; the applied/ copy is the audit trail.
    if (Test-Path $fromOutbox) { Remove-Item -Recurse -Force $fromOutbox }
    Write-Host ""
    Write-Host "RETRY OK: $Batch -> applied/" -ForegroundColor Green
    Write-Host "If the pump is running with -Watch it will pick up from here on its own."
    exit 0
}

Write-Host ""
Write-Host "RETRY FAILED: $Batch is back in rejected/. The reason is in" -ForegroundColor Red
Write-Host "  sync\rejected\$Batch\apply_result.txt" -ForegroundColor Red
exit 1
