# Observability for a long-running sync

**Status:** DRAFT — design agreed 2026-08-15, nothing built yet
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

## 10. Retry

A command-line action this round: `sync-retry.ps1 <batch>` moves the batch directory from
`rejected/` back to `inbox/` and re-runs the applier. **It runs on the host**, because a
container cannot rename a directory on a Windows bind mount.

A Grafana button panel can be pointed at a thin HTTP wrapper later. The guard rails live
in the applier and the ledger either way, so no new safety logic is needed.

## 11. Open questions

1. Does the metrics script run as a host scheduled task, or as a loop in a small container
   mounting `sync/` **read-only**? Read-only sidesteps the rename constraint entirely,
   since it never moves anything.
2. Should record payloads go into Loki? `apply_result.txt` clearly yes. Shipping `.csv`
   and `.dat` would duplicate record content into a log store, which is a retention and
   data-protection question rather than a technical one.
3. Retention: nothing prunes `applied/` today. Observability makes this visible rather
   than causing it.
4. Compose layout: suggest a dedicated `observability` profile so the sync still runs
   without it.
5. Does the payload inspector (approach B) return in a later round, once there is real
   operational experience to justify it?

## 12. Success criteria

1. Killing the pump raises an alert within two minutes with nobody watching.
2. A deliberately failed batch shows a non-zero rejected count, and its reason is readable
   without opening a terminal.
3. Rows applied and last applied batch are visible at a glance.
4. Oracle-to-Adabas lag is a number on a screen.
5. **The sync still runs correctly with the entire observability stack stopped.**

## 13. Build order

1. Heartbeat writes in the pump and the capture engine. Smallest change, highest value,
   prerequisite for the alert that matters most.
2. Metrics script producing the `.prom` textfile.
3. Prometheus, Grafana and an exporter in compose under an `observability` profile.
4. Dashboard: health strip, queue depths, applied total, lag, rejected list.
5. Stall and rejected alert rules. **At this point the original problem is solved.**
6. Loki and Alloy for failure-reason detail.
7. JMX agent and Oracle exporter for engine and lag metrics.
8. `sync-retry.ps1`, and only then consider a button.

## 14. Before building any of it

Run the sync unattended for a full day, then kill the pump at a random moment and walk
away. Come back and time how long it takes to work out, from the terminal alone, that it
stopped, which batch it stopped on, and why.

That number is the baseline the dashboard has to beat, and the only honest measure of
whether this was worth building.
