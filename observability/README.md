# Watching the sync

```bat
sync-monitor.cmd          :: start it   (Grafana http://localhost:3000/d/o2a-sync)
sync-monitor.cmd stop     :: stop it    (the sync keeps running)
```

Design of record: [`../specs/sync-observability.md`](../specs/sync-observability.md).
This file is what got built, and the parts of it worth knowing before changing anything.

## The problem this solves

The bulk migration in the sibling repo is a one-shot: it ends `VERIFIED: 5/5` and is done.
This sync never ends, and that is the whole difference.

**The pump halts on the first failed batch and says nothing.** Halting is correct — batches
apply in order and the ledger refuses anything not newer than its watermark, so skipping a
failed batch would leave a permanent, silent gap. But a process that fails safe and stays
quiet is, for an unattended service, worse than one that crashes loudly: nothing
distinguishes *stopped* from *idle*.

Everything here exists to make that one failure loud.

## What it is

Four containers, all in the `observability` profile, none of which the sync depends on:

| | |
|---|---|
| `sync-exporter` | turns the `sync/` directory tree into metrics; also receives Alertmanager's webhook |
| `prometheus` | scrapes and evaluates the alert rules |
| `alertmanager` | delivers them |
| `grafana` | the dashboard, provisioned from this repo |

**An observer, never a dependency.** `/sync` is mounted **read-only** into the only
container that reads it, so nothing here can rename a batch directory even by accident —
and the sync runs correctly with all four stopped. That is a success criterion, not a
nicety.

## The one new mechanism: heartbeats

Prometheus cannot see a directory, and no counter can distinguish a stopped pump from an
idle one — both show an empty queue and no activity. So the pump and the capture engine
each write a small file on a timer:

```
sync/state/pump.heartbeat        written by scripts/sync-pump.ps1  (-Watch only)
sync/state/capture.heartbeat     written by capture/…/CaptureMain.java
```

`epoch=` is the only field that matters; the exporter turns it into
`sync_pump_heartbeat_age_seconds`, and the alert fires at 75 seconds plus a 15-second
`for`. Measured end to end, killing the pump put a line in `alerts.log` **109 seconds**
later. Without this file none of the rest is worth having.

Two deliberate choices:

- **The pump beats only in `-Watch` mode.** A one-shot run — which is how `sync-verify.ps1`
  drives it — is not a service, and must not leave a heartbeat that then goes stale and
  alerts through the whole test suite.
- **A deliberate stop still alerts.** That is not a false positive. For something meant to
  run continuously, *stopped* is the condition being alerted on. Start the pump to clear it.

## Where the numbers come from

Nothing is instrumented in the sync path. The exporter walks the queue every ten seconds:

| Metric | Read from |
|---|---|
| `sync_batches_outbox` / `_inbox` / `_rejected` | directory counts, `_COMPLETE` only |
| `sync_batches_applied_total` | `applied/` |
| `sync_records_applied_total{outcome}` | the `SUMMARY` line the appliers write |
| `sync_last_applied_batch` / `_scn` | newest `applied/batch-NNNNNN/batch_info.dat` |
| `sync_pump_halted`, `sync_pump_halt_info{batch,stage}` | the pump's own heartbeat |
| `sync_capture_echoes_filtered_total` | capture's heartbeat — the loop-prevention leak metric |
| `sync_batch_rejected{batch,reason}` | `apply_result.txt` inside each rejected batch |

That last row is the reason there is no log pipeline in this round. The pump writes the
applier's output **into the batch directory** before acknowledging it, so a rejected batch
carries its explanation with it and Grafana can table the reason directly. Loki would add
searchable history across batches; it would not add this.

It is written from the host rather than by `run-apply.sh` because the batch directory is
created by the Hop container (uid 501) and the Natural container runs as sagadmin, so a
copy from inside fails with EACCES - and writing from the host also captures the Natural
screen dump when an apply *crashes*, which is exactly when the reason is needed.

## Alerts

Rules: [`prometheus/alerts.yml`](prometheus/alerts.yml). Delivery: a webhook to a file.

Every receiver Alertmanager ships — email, Slack, PagerDuty — needs the internet, and this
lab is air-gapped by requirement. So notifications land in **`sync/alerts/alerts.log`**,
one line each, plus the full payload in `alerts.jsonl`. Crude, and exactly the point: the
alert survives with nobody watching, which a dashboard cannot do. In a real deployment the
same webhook points at whatever the operator already runs.

```
2026-08-18T12:20:46Z  FIRING    SyncPumpStopped   The pump is not running - nothing is being applied to Adabas
```

The five rules that matter, in order of value: pump stopped · capture stopped · pump
halted · batches rejected · queue not draining. A sixth, `SyncExporterDown`, exists because
monitoring that fails quietly turns "no alerts" from good news into no news.

## Retry

```bat
scripts\sync-retry.ps1                       :: list what is waiting, with reasons
scripts\sync-retry.ps1 -Batch batch-000007
scripts\sync-retry.ps1 -Batch batch-000007 -Remap   :: re-run the Hop mapping first
```

Retry is safe by construction: the ledger refuses an already-applied batch,
compare-before-write makes a re-apply a no-op, and the pump halted rather than skipped, so
nothing after the failure was ever applied.

**Skip is the operation that must not exist**, at any effort level. The script therefore
*refuses* to retry a batch while an older one is still unapplied, rather than trusting
whoever is at the keyboard to notice. It runs on the host because a container cannot rename
a directory on a Windows bind mount — the same constraint that put the acknowledgement in
`sync-pump.ps1`.

## Editing it

- **The dashboard is a file** (`grafana/dashboards/sync-overview.json`) and is provisioned
  read-only. Changes made in the Grafana UI are discarded on restart — export the JSON and
  commit it instead.
- Alert rules reload with `curl -X POST http://localhost:9090/-/reload`; Prometheus runs
  with `--web.enable-lifecycle`.
- The exporter re-reads its script every ten seconds only in the sense that it *runs* it —
  editing `exporter/sync-metrics.sh` needs
  `docker compose --profile observability restart sync-exporter`.
- Ports added by this stack: **3000, 9090, 9093, 9101**.

## What is deliberately not here

- **No Loki, no log pipeline.** Failure *reasons* already reach the dashboard through the
  rejected-batch labels. Loki buys searchable history across batches — worth having, not
  worth having first.
- **No JMX metrics from the Debezium engine** (connector status, milliseconds behind
  source). The agent is a one-line change to how the jar is launched; the heartbeat already
  answers the question that mattered.
- **No Oracle lag figure.** A real one compares Oracle's `CURRENT_SCN` against
  `sync_last_applied_scn` and needs the Oracle DB exporter. Until then `SyncFallingBehind`
  approximates it with "work queued and nothing acknowledged for fifteen minutes".
- **No payload inspector.** Approach B in the spec — one record shown as an Oracle row, a
  CSV line, a fixed-width line and an Adabas record. `TESTING_GUIDE.md` §2 does it by hand;
  whether it deserves an application is a question for after some operational experience.
- **No start/stop/pause buttons.** The system is already safe to stop and restart at any
  point, and pausing is just not running the pump. The verbs with value are: is it moving,
  what failed, why, retry.
