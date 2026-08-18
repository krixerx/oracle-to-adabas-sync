# Oracle → Adabas log-based sync lab

A complete, runnable example of capturing committed changes from **Oracle's redo log**
and applying them back into **Adabas** — not by writing to the database directly, but
**through a Natural program**, so the mainframe's own business logic still runs.

No message broker, no polling, no commercial licences. One command:

```bat
sync-verify.cmd
```

It ends with **`SYNC VERIFIED: 11/12 (1 skipped by design)`** and exit code 0. The
remaining criterion is conflict detection — a documented out-of-scope item for this
round, not a broken test. See [Why 10 and not 11](#why-10-and-not-11).

> **The other direction lives in a sibling repo:** [`adabas-to-oracle-migration`](https://github.com/krixerx/adabas-to-oracle-migration)
> — the bulk Adabas → Oracle migration that produces the relational model this sync
> writes back from. If you are wondering why Oracle holds an Adabas-shaped schema, that
> repo is the answer.

**What is synchronised:** two aggregates with deliberately different shapes.

- The **traffic fine** — Adabas file 20 `TRAFFINE`, Oracle `traffic_fine` plus two child
  tables. One multiple-value field (offences from a single stop) and one periodic group
  (part payments), so it exercises MU and PE occupancy, packed amounts, numeric dates and
  three reverse code lookups.
- The **vehicle** — Adabas file 12, which holds **one record per plate**. An Oracle
  vehicle with three plates is three Adabas records, so writing it back reconciles a set
  of records rather than occupancy inside one.

**Nothing is ever deleted.** A fine is *cancelled* (status `C`); a registration *expires*
(`PLATE-EXPIRY`). An `op=D` reaching the applier is **refused** and the batch stops — the
mainframe's own rule rejecting a write the source allowed.

## What it demonstrates

| | |
|---|---|
| **Log-based capture** | Oracle redo → LogMiner → Debezium embedded engine. Sees deletes and intermediate states, needs no `LAST_MODIFIED` column, puts zero load on application tables |
| **Files as a durable queue** | Sequence-numbered batch directories with a `_COMPLETE` marker written last, and an atomic directory rename as the acknowledgement. No Kafka |
| **Aggregate re-read** | Debezium *notifies*; Oracle supplies the payload. Rather than reconstructing a record from row deltas, the whole aggregate is re-read with ordinary SQL — which makes MU/PE set replacement and idempotent apply fall out for free |
| **Apply through business logic** | A Natural apply API writes to Adabas, so validation and derived fields still run. Replication products that write directly into Adabas bypass all of it |
| **Loop prevention** | Originator filtering at capture (drop anything written by the apply user) plus compare-before-write at apply. Filter for efficiency, compare for safety |
| **Transactional watermark** | The apply ledger is written in the *same* Adabas `ET` as the data change, so "applied but not recorded" is impossible |

## Architecture

```
Oracle 23ai Free                                          Adabas CE
  COMMIT                                                    file 20 TRAFFINE
    │ redo log                                                    ▲
    ▼                                                             │
  LogMiner ──▶ Debezium (embedded, no broker)                     │
                    │                                             │
                    ▼                                             │
            originator filter  ── drops SYNCAPP's own writes      │
                    │                                             │
                    ▼                                             │
            transaction buffer                                    │
                    │                                             │
                    ▼                                             │
       re-read whole aggregate from Oracle                        │
                    │                                             │
                    ▼                                             │
       sync/outbox/batch-NNNNNN/ + _COMPLETE     (CSV)            │
                    │                                             │
                    ▼                                             │
       Hop Server (warm JVM, REST)  ── reverse field mapping,     │
                    │                   reverse CODE_LOOKUP       │
                    ▼                                             │
       sync/inbox/batch-NNNNNN/     (fixed-width)                 │
                    │                                             │
                    ▼                                             │
              APPLYFIN (Natural) ─── through business logic ──────┘
                    │
                    └──▶ ledger file 99, same ET as the data change
                    └──▶ atomic rename to applied/ or rejected/
```

**Two format choices worth explaining.** Capture → Hop is **CSV** (Hop reads it
natively). Hop → Natural is **fixed-width**, because `READ WORK FILE <structure>` parses
positionally for free — no delimiter, quoting or empty-vs-NULL handling to get wrong in
the leg that writes to the database, and a bad layout fails loudly instead of shifting
values sideways. Details in [`CHANGE_FILE_CONTRACT.md`](CHANGE_FILE_CONTRACT.md).

**Why Hop Server and not `hop-run` per batch?** Measured: 0.4 s warm against 23 s cold —
a 54× gap. The end-to-end latency budget is 5–10 s, so a JVM per batch would spend
several times the whole budget on startup.

## Quick start

First run ever, in this order:

```bat
mvn -f capture\pom.xml package     :: build the capture engine
scripts\lab-up.ps1                 :: bring the lab up
scripts\setup-cdc.ps1              :: ONE TIME: Oracle ARCHIVELOG + supplemental logging + users
scripts\setup-adabas-ledger.ps1    :: ONE TIME: Adabas file 99, the apply watermark
sync-verify.cmd                    :: the acceptance suite
```

`lab-up.ps1` must come first — the two setup scripts `docker cp` into running
containers. It also runs `seed-source.ps1`, which manufactures the **Adabas** side of the
post-migration state: the Community Edition demo database has no VIN, no vehicle-type
field and no traffic-fine file at all, so file 20 is created with ADAFDU and filled
deterministically. That is the mirror of `oracle-init/04_seed.sql` on the Oracle side, and
it has to be redone after every `docker compose down -v`.

To watch the sync work continuously instead of running the test suite:

```bat
docker compose --profile sync up -d hop-server
java -jar capture\target\oracle-capture.jar capture\capture-local.properties
scripts\sync-pump.ps1 -Watch
```

Then change something in Oracle and watch it arrive in Adabas:

```bat
docker exec -it o2a-oracle sqlplus pocapp/pocapp@//localhost:1521/FREEPDB1
  UPDATE pocapp.traffic_fine SET location = 'MYTEST' WHERE fine_no = 'F000000005';
  COMMIT;
check-fine.cmd F000000005          :: shows the Oracle row and the Adabas record side by side
check-vehicle.cmd CITZZ1JZW00000014 :: same, for a vehicle and all of its plate records
```

A stage-by-stage walkthrough — the same record seen as an Oracle row, a CSV, a
fixed-width line and an Adabas record — is in [`TESTING_GUIDE.md`](TESTING_GUIDE.md),
including an experiment that breaks the MU/PE shrink on purpose so you can see the
corruption first-hand.

## Watching it

```bat
sync-monitor.cmd                 :: Grafana http://localhost:3000/d/o2a-sync
sync-monitor.cmd stop            :: stop it; the sync carries on
scripts\sync-retry.ps1          :: list failed batches with their reasons
scripts\sync-retry.ps1 -Batch batch-000007
```

The sync is meant to run for a long time, and its dangerous failure is not a crash: **the
pump halts on a failed batch and says nothing.** Halting is correct - skipping would move
the ledger watermark past the failure and leave a permanent silent gap - but for an
unattended service, stopped-and-quiet is indistinguishable from idle.

So the pump and the capture engine write a heartbeat, an exporter turns the `sync/`
directory tree into Prometheus metrics, and Alertmanager posts to a file sink:
**killing the pump puts a line in `sync/alerts/alerts.log` within about 110 seconds, with
no browser open.** That file, not the dashboard, is the deliverable. Details and the
deliberate omissions are in [`observability/README.md`](observability/README.md).

It is an observer, never a dependency: separate compose profile, no `depends_on` either
way, and `/sync` mounted read-only, so the sync runs identically with all of it stopped.

## Why 11 and not 12

Criterion 10 is conflict detection: the same record changed on both sides inside one
sync window. It is **out of scope for this round by decision, not unmet by accident**,
so the suite reports it as `SKIP` and still exits 0.

Most of the work is already done. `ALL COLUMNS` supplemental logging means Oracle's redo
already carries the full before-image at no extra cost, and the applier already reads the
target record for the MU/PE read-modify-write. What is missing is emitting the
before-image as `prev_*` columns and comparing against it: Adabas matches the new value →
already applied, skip; matches the before-image → expected state, apply; matches
neither → someone changed Adabas independently, so reject and alert.

## The MU/PE trap

The sharpest thing this lab teaches, and the reason the `SPIKE*` Natural programs are
kept even though nothing invokes them:

**Lowering an Adabas occurrence count does not remove the trailing occurrences.** They
survive as stale residue *and the count stays put*. You must `RESET <field>(n+1:max)`
**before** lowering the count.

**A periodic group is worse.** An occurrence stays alive while *any* field in it holds
data — including fields your sync never maps. So a removed occurrence needs every field
cleared, mapped or not, while surviving occurrences must keep theirs untouched.

That makes "which Adabas fields are unmapped?" a **correctness** question for write-back,
not merely a completeness one. `natural/SPIKEMU.NSP` demonstrates it in isolation.

## Prerequisites

One-time, and they need internet. After this the lab runs fully offline.

1. **Docker Desktop.** ≥16 GB host RAM recommended (WSL `.wslconfig` memory ≥ 8 GB).
2. **`docker login`** with a free Docker Hub account — the Adabas and Natural
   Community Edition images require it.
3. **JDK 21** and **Maven**, to build `capture/`. Set `JAVA_HOME`, or have `java` on PATH.
4. **Images:** `softwareag/adabas-ce`, `softwareag/natural-ce`,
   `gvenzl/oracle-free:23-slim`, `apache/hop:latest`.
5. **Oracle JDBC driver.** Download `ojdbc11.jar` and put it in **`hop/lib/`**.
   It is not in this repo (Oracle OTN licence). `sync-verify.cmd` checks for it and
   stops with a clear message if it is missing — otherwise Docker would create a
   *directory* with that name and Hop Server would fail obscurely.
   → https://www.oracle.com/database/technologies/appdev/jdbc-downloads.html

⚠️ **Ports.** This lab publishes **60001, 8190, 2700, 1521, 8081**, plus
**3000, 9090, 9093, 9101** when the observability profile is up. The sibling
`adabas-to-oracle-migration` repo publishes all of the first group except 8081. **Stop one
lab before starting the other** — they are designed to run one at a time.

⚠️ **Disk.** `setup-cdc.ps1` puts Oracle into `ARCHIVELOG` mode. There is no `rman` in
`gvenzl/oracle-free:23-slim`, so archive logs go to a plain directory rather than the
FRA. Run `scripts/purge-archivelogs.sh` periodically, or a long-running lab will fill
the disk.

## Layout

```
sync-verify.cmd              the acceptance suite (12 criteria)
sync-start.cmd               start capture + pump for interactive use
sync-monitor.cmd             start/stop the monitoring stack (Prometheus + Grafana)
check-fine.cmd               show one fine in Oracle and Adabas side by side
check-vehicle.cmd            same for a vehicle: attributes plus every plate record
docker-compose.yml           adabas, natural, oracle, hop-server
CHANGE_FILE_CONTRACT.md      the capture → Hop → Natural interface
specs/                       the full design: decisions, spikes, open items
oracle-init/                 schema, lookups, CDC setup, post-migration seed
capture/                     Java: Debezium embedded engine, assembler, batch writer
hop/pipelines/               60 fine · 70 offences (MU) · 71 payments (PE)  (reverse mapping)
natural/                     APPLYFIN (apply API) · DUMPFIN (assertions) · SEED* (Adabas source state) · LEDGER · SPIKE* demos
scripts/                     setup-cdc · setup-adabas-ledger · seed-source · sync-pump · sync-retry · sync-verify · lab-up
observability/               exporter · Prometheus rules · Alertmanager · provisioned Grafana dashboard
sync/                        outbox / inbox / applied / rejected (gitignored)
```

## Licence

Code in this repository: **Apache-2.0** (see [LICENSE](LICENSE)).

**Adabas & Natural Community Edition** — the Docker images this lab runs on — are
licensed by Software AG for **personal use and learning only**; commercial production
use is prohibited.

`oracle-init/04_seed.sql` contains a snapshot of the demo dataset in its
post-migration relational form, so the sync has something to operate on without
requiring the sibling migration repo. It derives from the Software AG Community Edition
demo files and is included for that purpose only.

The Oracle JDBC driver is not included; it carries Oracle's OTN licence and you download
it yourself (see Prerequisites).
