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
$state   = Join-Path $poc "sync\state"
# Endpoint names are execPipeline / execWorkflow - NOT executePipeline /
# executeWorkflow, which 404 with a bare Jetty error page rather than a
# Hop <webresult>, so the failure looks like a server problem.
$hopUrl  = "http://localhost:8081/hop/execWorkflow"
$hopAuth = "cluster:cluster"

# ---------------------------------------------------------------- heartbeat --
#
# The one new mechanism the observability design needed, and the reason it works
# at all: NOTHING ELSE DISTINGUISHES A STOPPED PUMP FROM AN IDLE ONE. Both show
# an empty queue, no activity and no errors. A file whose timestamp stops
# advancing is the difference, and it is what the two-minute stall alert reads.
#
# Written only in -Watch mode. A one-shot run (which is how sync-verify.ps1
# drives the pump) is not a service and must not leave a heartbeat that then
# goes stale and alerts.
#
# halted is reported by the pump itself rather than inferred from a queue that
# stopped draining - the pump knows the instant it happens, inference takes ten
# minutes. Note a deliberate stop also raises the stall alert after two minutes.
# That is not a false positive: for something meant to run continuously, stopped
# IS the condition being alerted on. Start the pump again to clear it.
$script:HeartbeatEnabled = $Watch.IsPresent
$script:AppliedThisSession = 0
# Halt state is sticky and lives here, NOT in the caller: the idle beat fires
# immediately after a halted pass, so if "idle" reset the flag the halt would be
# erased within seconds of being raised and no alert could ever see it. It is
# cleared only by a batch that actually applies.
$script:Halted = 0
$script:HaltBatch = ""
$script:HaltStage = ""

function Write-Heartbeat {
    param(
        [string]$Status = "idle",
        [string]$LastBatch = ""
    )
    if (-not $script:HeartbeatEnabled) { return }
    $Halted    = $script:Halted
    $HaltBatch = $script:HaltBatch
    $HaltStage = $script:HaltStage
    New-Item -ItemType Directory -Force $state | Out-Null
    $now = [DateTimeOffset]::UtcNow
    $lines = @(
        "epoch=$($now.ToUnixTimeSeconds())"
        "iso=$($now.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
        "role=pump"
        "status=$Status"
        "halted=$Halted"
        "halt_batch=$HaltBatch"
        "halt_stage=$HaltStage"
        "last_batch=$LastBatch"
        "applied_session=$($script:AppliedThisSession)"
    )
    # Written whole, not appended: a reader that catches a half-written file
    # would parse a stale epoch and mis-report the age.
    [System.IO.File]::WriteAllText((Join-Path $state "pump.heartbeat"),
        ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

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

# The applier's verdict, kept WITH the batch so it travels into applied/ or
# rejected/ when the directory is renamed. This is what makes "what failed and
# why" answerable afterwards: /sync/work is scratch and the next run wipes it,
# so a rejected batch would otherwise arrive with no explanation.
#
# Written here rather than by run-apply.sh because the batch directory is
# created by the Hop container (uid 501) and the Natural container runs as
# sagadmin - a copy from inside it fails with EACCES. Writing from the host is
# also strictly more useful: this captures the Natural screen dump when the
# apply CRASHES, not just the SUMMARY line when it completes.
function Save-ApplyResult([string]$batch, $output) {
    $dir = Join-Path $inbox $batch
    if (-not (Test-Path $dir)) { return }
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $dir "apply_result.txt"), $text + "`n",
        (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Apply([string]$batch) {
    $out = docker exec o2a-natural sh /poc/natural/run-apply.sh $batch 2>&1
    $ok = ($LASTEXITCODE -eq 0)     # read it before anything else clobbers it
    $out | ForEach-Object { Write-Host "    $_" }
    Save-ApplyResult $batch $out
    return $ok
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
        Write-Heartbeat -Status "working" -LastBatch $b.Name
        if (-not (Invoke-Mapping $b.Name)) {
            Write-Host "  HALTING: mapping failed for $($b.Name). Later batches are" -ForegroundColor Yellow
            Write-Host "  left untouched so ordering is preserved - fix and re-run." -ForegroundColor Yellow
            $script:Halted = 1; $script:HaltBatch = $b.Name; $script:HaltStage = "mapping"
            Write-Heartbeat -Status "halted" -LastBatch $b.Name
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
            $script:AppliedThisSession++
            # A batch that applies proves the pipeline works again.
            $script:Halted = 0; $script:HaltBatch = ""; $script:HaltStage = ""
            Write-Heartbeat -Status "working" -LastBatch $b.Name
        } else {
            Write-Host "  HALTING: apply failed for $($b.Name) (routed to rejected/)." -ForegroundColor Yellow
            $script:Halted = 1; $script:HaltBatch = $b.Name; $script:HaltStage = "apply"
            Write-Heartbeat -Status "halted" -LastBatch $b.Name
            break
        }
    }
    return $done
}

if ($Watch) {
    Write-Host "pump watching $outbox (Ctrl-C to stop)"
    # Beat once before the first pass, so a pump that starts into an empty queue
    # is immediately visible as running rather than as never-started.
    Write-Heartbeat -Status "starting"
    while ($true) {
        $n = Invoke-Once
        if ($n -eq 0) {
            # The idle beat. In -Watch mode the outbox copy of a failed batch is
            # left in place deliberately, so the next pass retries it - which is
            # what carries the sync through a transient Adabas or Hop outage.
            # The halted flag therefore clears itself when a retry succeeds.
            Write-Heartbeat -Status $(if ($script:Halted) { "halted" } else { "idle" })
            Start-Sleep -Seconds $IntervalSec
        }
    }
} else {
    $n = Invoke-Once
    Write-Host "pump: $n batch(es) applied"
}
