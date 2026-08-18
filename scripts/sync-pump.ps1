# The batch pump: carries every ready batch from sync/outbox through Hop
# mapping into sync/inbox, then applies it to Adabas.
#
#   outbox/batch-N  --(Hop Server, warm JVM)-->  inbox/batch-N
#                   --(APPLYFIN through Natural)-->  Adabas
#                   --(atomic rename)-->  applied/batch-N
#
# Deliberately a thin loop over the pieces rather than a daemon: each stage
# is independently runnable and independently debuggable, which is what a
# POC needs. In production this becomes a service.
#
# Usage:
#   sync-pump.ps1              process every ready batch once, then exit
#   sync-pump.ps1 -Watch       keep polling for new batches
#   sync-pump.ps1 -IntervalSec 3
param(
    [switch]$Watch,
    [int]$IntervalSec = 3
)
$ErrorActionPreference = "Stop"
$poc = Split-Path -Parent $PSScriptRoot
$outbox  = Join-Path $poc "sync\outbox"
$inbox   = Join-Path $poc "sync\inbox"
# Endpoint names are execPipeline / execWorkflow - NOT executePipeline /
# executeWorkflow, which 404 with a bare Jetty error page rather than a
# Hop <webresult>, so the failure looks like a server problem.
$hopUrl  = "http://localhost:8081/hop/execWorkflow"
$hopAuth = "cluster:cluster"

function Get-ReadyBatches {
    if (-not (Test-Path $outbox)) { return @() }
    # _COMPLETE is the commit point of the file protocol: a directory without
    # it may still be being written, so it is not ours to touch.
    Get-ChildItem $outbox -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "_COMPLETE") } |
        Sort-Object Name    # batch numbers are zero-padded, so name order IS batch order
}

function Invoke-Mapping([string]$batch) {
    $in  = "/sync/outbox/$batch"
    $out = "/sync/inbox/$batch"
    $url = "$hopUrl/?workflow=/poc/hop/workflows/sync-apply.hwf&runConfig=local&level=Basic" +
           "&BATCH_IN=$in&BATCH_OUT=$out"
    # curl.exe returns an ARRAY of lines to PowerShell; join before matching
    # or truncating, or the failure path throws instead of reporting.
    $resp = (curl.exe -s -u $hopAuth --max-time 300 $url) -join "`n"
    if ($resp -notmatch "<result>OK</result>") {
        Write-Host "  MAPPING FAILED for $batch"
        $flat = ($resp -replace "\s+", " ")
        Write-Host ("  " + $flat.Substring(0, [Math]::Min(700, $flat.Length)))
        return $false
    }
    return $true
}

function Copy-BatchInfo([string]$batch) {
    # batch_info.dat carries the batch number and end SCN to the applier.
    # Generated here rather than in Hop: it is metadata about the batch, not
    # a mapped data row, and Hop has no row to hang it on.
    $manifest = Get-Content (Join-Path $outbox "$batch\manifest.json") -Raw | ConvertFrom-Json
    $line = ("{0:d6}{1}" -f [int]$manifest.batch, ([string]$manifest.end_scn).PadLeft(15, '0'))
    $dir = Join-Path $inbox $batch
    New-Item -ItemType Directory -Force $dir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir "batch_info.dat"), "$line`n",
        (New-Object System.Text.UTF8Encoding($false)))
    # _COMPLETE last, same rule as the capture side.
    [System.IO.File]::WriteAllText((Join-Path $dir "_COMPLETE"), "",
        (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Apply([string]$batch) {
    $out = docker exec o2a-natural sh /poc/natural/run-apply.sh $batch 2>&1
    $out | ForEach-Object { Write-Host "    $_" }
    return ($LASTEXITCODE -eq 0)
}

# The acknowledgement. A same-volume Move-Item on NTFS is atomic, which is
# the property the file protocol relies on.
#
# It happens HERE and not inside the container because Docker Desktop's
# Windows bind mount refuses a directory rename from the container side
# ("mv: Permission denied") regardless of permissions. On a real Linux
# deployment the applier would do this itself right after ET. The split is
# safe: a crash between apply and acknowledgement leaves the batch in the
# inbox and it is simply re-applied, which is a no-op by construction.
function Complete-Batch([string]$batch, [bool]$ok) {
    $src  = Join-Path $inbox $batch
    $dest = Join-Path $poc ("sync\" + $(if ($ok) { "applied" } else { "rejected" }))
    New-Item -ItemType Directory -Force $dest | Out-Null
    $target = Join-Path $dest $batch
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Move-Item $src $target
    Write-Host ("    ACK {0} -> {1}/" -f $batch, (Split-Path $dest -Leaf))
}

function Invoke-Once {
    $batches = Get-ReadyBatches
    if (-not $batches) { return 0 }
    $done = 0
    foreach ($b in $batches) {
        Write-Host "== $($b.Name) =="

        # HALT on failure - never skip to the next batch.
        #
        # Batches must be applied in order, and the ledger refuses anything
        # not newer than its watermark. So if batch N fails and the pump
        # carries on with N+1, the watermark moves past N and N can NEVER be
        # applied afterwards: a permanent, silent gap in the synchronised
        # data. Stopping keeps the queue ordered and makes the failure loud.
        if (-not (Invoke-Mapping $b.Name)) {
            Write-Host "  HALTING: mapping failed for $($b.Name). Later batches are" -ForegroundColor Yellow
            Write-Host "  left untouched so ordering is preserved - fix and re-run." -ForegroundColor Yellow
            break
        }
        Copy-BatchInfo $b.Name
        $ok = Invoke-Apply $b.Name
        Complete-Batch $b.Name $ok
        if ($ok) {
            # The outbox copy has served its purpose once the batch is applied;
            # the inbox copy is what moved to applied/ and is the audit trail.
            Remove-Item -Recurse -Force $b.FullName
            $done++
        } else {
            Write-Host "  HALTING: apply failed for $($b.Name) (routed to rejected/)." -ForegroundColor Yellow
            break
        }
    }
    return $done
}

if ($Watch) {
    Write-Host "pump watching $outbox (Ctrl-C to stop)"
    while ($true) {
        $n = Invoke-Once
        if ($n -eq 0) { Start-Sleep -Seconds $IntervalSec }
    }
} else {
    $n = Invoke-Once
    Write-Host "pump: $n batch(es) applied"
}
