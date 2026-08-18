# Observability for a long-running sync

**Status:** BUILT 2026-08-18 — steps 1-5 and 8 of the build order are in the repo and
verified end to end; steps 6-7 (Loki, JMX, Oracle lag) are not. See §13.
**Scope:** Monitoring, alerting and failure inspection for the Oracle → Adabas sync.
No change to capture, Hop, Natural or the batch protocol.
**Companion:** [`oracle-to-adabas-sync.md`](oracle-to-adabas-sync.md) — the sync design itself

---

## 1. Problem

The sync runs continuously and is meant to keep running for a long time. Its sibling, the
Adabas → Oracle bulk migration, is a one-shot: it ends with `VERIFIED: 5/5` and is done.
This one never ends, and that difference is the whole reason this document exists.

Today the only interface is a terminal. For something long-running that is not enough:
warnings and errors have to be found by scrolling, there is no running count of what
synchronised successfully, no list of what failed and why, and no way to retry a failed
batch except by hand.

Three requirements:

1. How much has synchronised successfully.
2. How many and **what** failed, and **why**, with a detail view.
3. Can a failed sync be retried.

## 2. The failure mode that actually matters

The pump halts on the first failure. That is correct and deliberate: batches apply in
order, and the ledger refuses any batch not newer than its watermark, so skipping a failed
batch would move the watermark past it and that batch could then never be applied. A
permanent, silent gap.

But **nothing announces the halt.** The system fails safe and stays quiet. For an
unattended process, silent-and-stopped is more dangerous than crashed-and-loud, because
nothing distinguishes it from idle. Any observability work has to solve this first.

## 3. What makes this pipeline unusual

It stores its own evidence. Every batch is a durable directory holding the exact CSV that
came out of Oracle, the exact fixed-width file that went into Natural, a `manifest.json`
with row counts and SCN range, and `apply_result.txt` with a per-record outcome and
reason. Batches move between `outbox/`, `inbox/`, `applied/` and `rejected/` by atomic
rename.

Generic replication monitoring keeps counters and discards the payload. This design kept
the payload for free, as a side effect of using files as a durable queue.

## 4. Constraints

- Runs offline after image pulls. Everything must be self-hostable.
- Windows host, Docker Desktop. **A container cannot rename a directory on a Windows bind
  mount**, which is why the pump performs acknowledgement renames on the host. Anything
  that moves batch directories inherits this.
- Existing toolchain: JDK 21 + Maven, Apache Hop, PowerShell, Natural/Adabas and Oracle in
  containers.
- The observability stack must be an **observer, never a dependency**. The sync must run
  correctly with all of it stopped.

## 5. Premises

1. The bulk migration gets no UI. One-shot, verified, done.
2. The dangerous failure is a silent stall, not a crash.
3. Retry is safe. **Skip must never exist**, at any effort level. Retry is safe because
   compare-before-write makes re-applying identical data a no-op, the ledger refuses
   already-applied batches, and the pump halts rather than skips, so nothing after the
   failed batch was ever applied.
4. Observability reads existing state. No new database.
5. Start / pause / stop is the least valuable requested feature, because the system is
   already safe to stop and restart at any point, and pausing is equivalent to not running
   the pump. The verbs with real value: is it moving, what failed, why, retry.

## 6. Landscape

- Debezium ships **no** built-in monitoring UI; the standalone Debezium UI was wound down.
- The Debezium Management Platform (2026) added monitoring, but targets **Debezium
  Server** via OpenTelemetry. This lab runs the **embedded engine** deliberately, because
  Debezium Server has no local-file sink, so the platform does not fit this shape.
- For embedded deployments the documented path is JMX metrics → Prometheus JMX exporter →
  Grafana.
- Nothing off-the-shelf covers "failed batch, reason, inspect, retry" for a queue made of
  directories. Commercial CDC platforms bundle equivalents but own the whole pipeline.

## 7. Approaches considered

| | Approach | Effort | Notes |
|---|---|---|---|
| A | Status command + alerting, no UI | S | Solves the stall cheaply; leaves "what failed" on the CLI |
| B | Custom read-only console over the filesystem | M | Answers all three asks, including a three-representation payload view; cost is an app to own |
| **C** | **Metrics and logs only, Grafana presents** | **M** | **CHOSEN.** No application code to own; standard shape; no payload inspector this round |

**C chosen.** It introduces no bespoke code to maintain, it is the conventional shape for
infrastructure observability, and it packages naturally (an exporter plus a provisioned
dashboard) if this is ever shared with others. The trade accepted: no payload inspector
in this round.

> A note for the record: an earlier claim that "dashboards are read-only, so Grafana cannot
> offer retry" is too strong. Grafana's Business Forms / Button panels can POST to an HTTP
> endpoint, and Loki can ingest `apply_result.txt` so failure reasons are searchable and
> filterable by batch. Grafana's real limit here is the three-representation payload view,
> not failure reporting.

## 8. Architecture

```
capture (java -jar, embedded Debezium)
   └─ -javaagent: JMX exporter ──────────────┐
                                             │
sync/ directories                            │
   └─ metrics script → *.prom textfile ──────┼──▶ Prometheus ──▶ Grafana
      (queue depths, heartbeats, watermark)  │        │           dashboards
                                             │        └──▶ alert rules
Oracle (CURRENT_SCN → lag)                   │
   └─ Oracle DB exporter, custom SQL ────────┘

apply_result.txt, capture.log
   └─ Grafana Alloy / Promtail ──▶ Loki ──▶ Grafana Explore
                                            (failure reasons, filtered by batch)
```

### 8.1 Queue state via the textfile collector

Prometheus cannot see directories. A scheduled script counts entries in each `sync/`
directory, reads the newest `manifest.json`, and writes a `.prom` file that node_exporter
or windows_exporter serves. This is the standard no-code pattern for exposing filesystem
state, and it carries most of this design's value.

`sync_batches_pending` · `sync_batches_applied_total` · `sync_batches_rejected` ·
`sync_rows_applied_total` · `sync_last_applied_batch` · `sync_last_applied_scn` ·
`sync_last_applied_timestamp_seconds`

### 8.2 Heartbeats — the one new mechanism required

Nothing today records that the pump is alive, so no monitoring stack can tell **stopped**
from **idle**. The pump and the capture engine each touch
`sync/state/pump.heartbeat` and `sync/state/capture.heartbeat` on a short interval; the
metrics script exposes their age.

`sync_pump_heartbeat_age_seconds` · `sync_capture_heartbeat_age_seconds`

Without this, option C solves nothing that matters. With it, it solves the failure that
actually bites.

### 8.3 Engine metrics via JMX

Run the capture jar with the Prometheus JMX exporter Java agent. Yields connector status,
log position, event counts and milliseconds-behind-source without touching capture's code.

### 8.4 Oracle lag

Oracle Database exporter with a custom query comparing `CURRENT_SCN` against the last
applied SCN, using `SCN_TO_TIMESTAMP` for a human-readable figure.

### 8.5 Failure detail via Loki

Grafana Alloy or Promtail tails `capture.log` and every `apply_result.txt`, extracting the
batch number into a label. Grafana Explore then answers "what failed and why" with a
filterable detail view.

## 9. Alert rules — the actual deliverable

| Rule | Meaning |
|---|---|
| `sync_pump_heartbeat_age_seconds > 120` | **The pump stopped. The most important rule here.** |
| `sync_capture_heartbeat_age_seconds > 120` | Capture stopped |
| `sync_batches_rejected > 0` | Something failed and is waiting for a human |
| `sync_batches_pending` rising over N minutes | Pump running but not draining |
| lag above threshold | Adabas falling behind Oracle |

**As built** (`observability/prometheus/alerts.yml`), with what the thresholds became and
why they moved:

| Rule | Expression | Notes |
|---|---|---|
| `SyncPumpStopped` | `sync_pump_heartbeat_age_seconds > 75` for 15s | 120s could not meet criterion 1 once Alertmanager grouping and scrape granularity were added on top. The floor on the threshold is the longest *legitimate* gap between beats - one batch's apply time. **Measured end to end: 109 s from killing the pump to a line in `sync/alerts/alerts.log`.** |
| `SyncCaptureStopped` | same, on capture | |
| `SyncPumpHalted` | `sync_pump_halted == 1` for 1m | New, and better than inferring a halt from a queue that stopped draining: the pump reports it directly. `for: 1m` because in `-Watch` mode the pump retries the failed batch, which is how it rides out a transient Hop or Adabas outage. |
| `SyncBatchRejected` | `sync_batches_rejected > 0` for 1m | |
| `SyncQueueNotDraining` | `pending > 0 and increase(applied_total[10m]) == 0` for 10m | The "rising over N minutes" rule, expressed as work waiting and nothing acknowledged. |
| `SyncFallingBehind` | `pending > 0 and time() - last_applied_timestamp > 900` for 5m | A stand-in for real lag until the Oracle exporter exists (8.4). |
| `SyncExporterDown` | `up{job="sync"} == 0` for 2m | New. Monitoring that fails quietly turns "no alerts" from good news into no news. |

**Delivery, which the design did not address:** every receiver Alertmanager ships needs the
internet, and this lab is air-gapped. Notifications therefore go by webhook to a file sink
inside the exporter container and land in `sync/alerts/alerts.log`. That file - not the
dashboard - is what satisfies "with nobody watching".

## 10. Retry

A command-line action this round: `sync-retry.ps1 <batch>` moves the batch directory from
`rejected/` back to `inbox/` and re-runs the applier. **It runs on the host**, because a
container cannot rename a directory on a Windows bind mount.

A Grafana button panel can be pointed at a thin HTTP wrapper later. The guard rails live
in the applier and the ledger either way, so no new safety logic is needed.

## 11. Open questions

1. ~~Host scheduled task or read-only container?~~ **ANSWERED by building: read-only
   container.** `/sync` is mounted `ro`, so the observer physically cannot rename a batch
   directory and the Windows bind-mount restriction stops being a consideration at all.
   One wrinkle found on the way: node_exporter's textfile collector was the intended
   vehicle and was dropped - inside a container its host metrics describe the container,
   so it would ship hundreds of irrelevant series to serve twenty. A stdlib HTTP server in
   the same container does the job. (Plain `alpine` could not: Alpine no longer ships the
   busybox `httpd` applet, and installing it would need the network on every start.)
2. Should record payloads go into Loki? Still open, and **less pressing than it looked**:
   `run-apply.sh` now copies the applier's result file *into the batch directory* before
   acknowledgement, so a rejected batch carries its own reason and the dashboard tables it
   with no log store at all. Loki would add searchable history across batches, not the
   reason itself. The `.csv`/`.dat` payload question is unchanged - retention and data
   protection, not technique.
3. Retention: still nothing prunes `applied/`, and it now has a second consequence -
   `sync_batches_applied_total` and `sync_records_applied_total` are computed from that
   directory, so pruning it reads as a counter reset.
4. ~~Compose layout~~ **DONE: an `observability` profile**, and `sync-monitor.cmd` names
   the four services explicitly, because a bare `--profile observability up` would also
   start every profile-less service and drag the databases up behind the monitoring.
5. Does the payload inspector (approach B) return in a later round, once there is real
   operational experience to justify it? Still open, and still the right question to defer.
6. **New: what should happen when the pump is stopped on purpose?** It alerts, at present,
   because *stopped* is exactly the condition being watched. That is right for a permanent
   service and irritating in a lab. Suppressing it needs a distinction between "stopped
   cleanly" and "died" - a real distinction, but one that would have made the criterion-1
   demonstration (kill the pump, wait for the alert) impossible to perform. Left as-is
   deliberately.

## 12. Success criteria

1. Met. Killing the pump raises an alert within two minutes with nobody watching.
   **Measured 2026-08-18: 109 seconds** from `Stop-Process` to the line appearing in
   `sync/alerts/alerts.log`, with no browser open.
2. Met. A deliberately failed batch shows a non-zero rejected count and its reason is
   readable without opening a terminal - `sync_batch_rejected{batch,reason}`, tabled on the
   dashboard and listed by `sync-retry.ps1` with no arguments.
3. Met. Rows applied and last applied batch are visible at a glance.
4. **NOT met as specified.** There is no true Oracle-to-Adabas lag figure: that needs the
   Oracle exporter comparing `CURRENT_SCN` against `sync_last_applied_scn` (8.4, build
   order step 7). What exists is the applied SCN, the age of the last acknowledgement, and
   an alert on work sitting undrained - useful, and not the same number.
5. Met. The sync still runs correctly with the entire observability stack stopped.
   Enforced structurally: separate profile, no `depends_on` in either direction, and
   `/sync` mounted read-only.

## 13. Build order

1. **Built.** Heartbeat writes in the pump and the capture engine. Smallest change,
   highest value, prerequisite for the alert that matters most.
2. **Built.** Metrics script producing the `.prom` textfile -
   `observability/exporter/sync-metrics.sh`.
3. **Built.** Prometheus, Grafana and an exporter in compose under an `observability`
   profile - plus Alertmanager and the file sink, which the design had not accounted for.
4. **Built.** Dashboard: health strip, queue depths, applied total, rejected table with
   reasons. No lag panel - see criterion 4.
5. **Built.** Stall and rejected alert rules. **The original problem is solved here.**
6. *Not built.* Loki and Alloy for failure-reason detail. Reasons already reach the
   dashboard through the rejected-batch labels, so what is missing is searchable *history*
   across batches, which is a smaller thing than it was when this list was written.
7. *Not built.* JMX agent and Oracle exporter. The JMX agent is a one-line change to how
   the jar is launched; the Oracle exporter is what turns criterion 4 from amber to green.
8. **Built.** `scripts/sync-retry.ps1`. No button - and note the script *refuses* to retry
   a batch while an older one is unapplied, which is the guard rail that matters more than
   the UI would.

**One thing built that the plan did not have:** the applier's output is written into the
batch directory before the acknowledgement, so it travels into `applied/` or `rejected/`
with the batch. Five lines in the pump, and it is what makes "what failed and why"
answerable without a log pipeline - it moved Loki from prerequisite to nice-to-have.

It belongs in `run-apply.sh` and cannot live there: the batch directory is created by the
Hop container as uid 501, the Natural container runs as sagadmin, and a copy from inside it
fails with EACCES. Writing from the host turned out to be better anyway - it captures the
Natural screen dump when an apply *crashes*, not only the SUMMARY line when it completes,
and the crash is the case where somebody actually needs the reason.

## 14. Before building any of it

Run the sync unattended for a full day, then kill the pump at a random moment and walk
away. Come back and time how long it takes to work out, from the terminal alone, that it
stopped, which batch it stopped on, and why.

That number is the baseline the dashboard has to beat, and the only honest measure of
whether this was worth building.

> **Not done.** This was built without measuring the baseline first, so the comparison it
> asks for does not exist. What can be said honestly is the other half: from a killed pump
> to a line in a file is **109 seconds, unattended**. Whether that beats a person noticing
> a stopped terminal window is a guess - an easy guess, but a guess. The experiment is
> still worth running once the lab has been left up for a day, and it is cheap now that
> both sides can be timed.
