# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A runnable lab that captures committed changes from **Oracle's redo log** and applies
them back into **Adabas** — not by writing to the database directly, but **through a
Natural program**, so the mainframe's own business logic still runs. No broker, no
polling, no commercial licences.

The acceptance criterion is the last line of the suite:

```bat
sync-verify.cmd     :: ends "SYNC VERIFIED: 10/11 (1 skipped by design)", exit 0
```

**10/11 is a passing run.** Criterion 10 is conflict detection — out of scope for this
round *by decision*, so it reports `SKIP` and does not fail the run. Do not "fix" it into
a failure, and do not quietly renumber the criteria to make it look like 10/10.

The opposite direction (bulk Adabas → Oracle) is the sibling repo
`adabas-to-oracle-migration`; this one writes back into the model that one produces.

## Commands

First run ever, **in this order** — `lab-up` must precede the setup scripts, which
`docker cp` into running containers:

```bat
mvn -f capture\pom.xml package     :: build the capture engine
scripts\lab-up.ps1                 :: containers up (clears a stale Adabas lock first)
scripts\setup-cdc.ps1              :: ONE TIME: ARCHIVELOG + supplemental logging + users
scripts\setup-adabas-ledger.ps1    :: ONE TIME: Adabas file 99, the apply watermark
sync-verify.cmd                    :: the acceptance suite
```

Running the sync for real instead of testing it:

```bat
sync-start.cmd                     :: lab + Hop Server + capture and pump, each in its own window
check-fine.cmd F000000005          :: one record, Oracle and Adabas side by side
```

`sync-start.cmd` is the whole live path. The pieces it starts, if you want them
separately:

```bat
docker compose --profile sync up -d hop-server
java -jar capture\target\oracle-capture.jar capture\capture-local.properties [seconds]
scripts\sync-pump.ps1 -Watch       :: or without -Watch: drain once and exit
```

The capture jar's optional second argument is a **run duration in seconds**
(`sync-start.cmd` passes 28800, so a forgotten window stops mining after 8 hours). Any
key in `capture-local.properties` can be overridden by the same name in upper snake case
as an environment variable (`DATABASE_HOSTNAME`) — that is how one file serves both a
host run (`localhost`) and an in-network run (`oracle`).

Ad-hoc SQL: `docker exec -it o2a-oracle sqlplus pocapp/pocapp@//localhost:1521/FREEPDB1`.
Container prefix is `o2a-` (the sibling lab uses `a2o-` — easy to mistype).

## Testing a change without running the whole suite

`scripts/sync-verify.ps1` is monolithic — **there is no flag to run a single criterion**,
it takes several minutes, and it is destructive: it clears `sync/`, resets the ledger,
rewrites fine `F000000005`, creates and deletes `FZZ9999999`, and **stops and restarts
Adabas** in criterion 9. Run it to prove the whole pipeline, not to iterate.

To iterate, drive one stage at a time (`TESTING_GUIDE.md` §2 is the long form):

```bat
:: map one outbox batch by hand - exactly what the pump's REST call does
curl -u cluster:cluster "http://localhost:8081/hop/execWorkflow/?workflow=/poc/hop/workflows/sync-apply.hwf&runConfig=local&level=Basic&BATCH_IN=/sync/outbox/batch-000001&BATCH_OUT=/sync/inbox/batch-000001"

powershell -File scripts\make-batch-info.ps1 batch-000001   :: batch_info.dat + _COMPLETE
docker exec o2a-natural sh /poc/natural/run-apply.sh batch-000001
docker exec o2a-natural sh /poc/natural/run-dump.sh F000000005
docker exec o2a-natural sh /poc/natural/run-reset-ledger.sh :: lets the same batch apply again
```

`run-dump.sh` (DUMPFIN) reads Adabas independently of the sync's own bookkeeping — which
is why assertions go through it and never through the ledger or the batch files.

What has to be rebuilt or restarted after an edit:

| Edited | Needed |
|---|---|
| `capture/**.java`, `capture.properties` | `mvn -f capture\pom.xml package`, restart the capture process |
| `hop/pipelines/*.hpl`, `hop/workflows/*.hwf` | nothing — Hop Server reads them off the bind mount per run |
| `hop/project-config.json`, `docker-compose.yml` | `docker compose --profile sync up -d hop-server` |
| `natural/*.NSP`, `*.NSD` | nothing — `run-apply.sh` re-copies and `ftouch`es the sources every run |
| the Adabas FDT (a new field) | `scripts/seed-source.ps1` **and** the sibling repo's copy, then `lab-up.ps1` |
| `oracle-init/*.sql` | `docker compose down -v`, or apply the DDL by hand (see below) |

## Where each concern lives

```
Oracle COMMIT → redo → LogMiner → Debezium embedded   capture/  (Java)
  → originator filter (drops SYNCAPP's own writes)    Assembler
  → transaction buffer → re-read whole aggregate      AggregateResolver
  → sync/outbox/batch-NNNNNN/ + _COMPLETE   (CSV)     BatchWriter
  → reverse field mapping, reverse CODE_LOOKUP        hop/pipelines/60,70,71
  → sync/inbox/batch-NNNNNN/            (fixed-width) Hop Server (warm JVM, REST)
  → apply through business logic                      natural/APPLYFIN.NSP
  → ledger file 99 in the SAME ET as the data         natural/LEDGER.*
  → atomic rename to applied/ or rejected/            scripts/sync-pump.ps1
```

- **Java does stream assembly** — what changed, which aggregate it belongs to, batching.
- **Hop does field mapping only** — code reversal, padding, truncation to Adabas widths.
  It is the reverse of the migration lab and uses the *same* `CODE_LOOKUP` table.
- **Natural does semantics** — MU/PE occupancy, validation, the ledger, the ET boundary.
- **The pump is the conveyor** — it owns ordering and the acknowledgement, nothing else.

The central simplification (decision D4): **Debezium notifies, Oracle supplies the
payload.** A row delta means only "aggregate X changed"; `AggregateResolver` then re-reads
X in full with ordinary SQL. Do not "optimise" this into reconstructing state from deltas
— full-set replacement, child-key resolution and idempotent apply all fall out of it.

**The synced aggregate is the traffic fine** — Adabas file 20 `TRAFFINE`, Oracle
`traffic_fine` + `traffic_fine_offence` (MU) + `traffic_fine_payment` (PE), keyed by
`FINE_NO`. One aggregate covers scalars, MU, PE, packed amounts, numeric dates and three
code lookups.

**Both aggregates are live**, and their shapes are deliberately opposite:

| | fine | vehicle |
|---|---|---|
| Adabas | file 20 `TRAFFINE`, ONE record | file 12, **one record PER PLATE** |
| children | MU offences + PE payments *inside* the record | a SET of records, each repeating the vehicle's attributes |
| match key | `FINE-NO` (`DE,UQ`) | `REG-NUM` (`DE,UQ`) — **not** the ISN |
| applier | `APPLYFIN` | `APPLYVEH` |

**Nothing is ever deleted** (2026-08-18, revising O4). A fine is *cancelled*
(`status_code='C'`), a registration *expires* (`PLATE-EXPIRY`, `00000000` = current).
`op=D` is **refused** by both appliers: they report `REFUSED-DELETE`, leave the record
alone, and **do not advance the ledger watermark**, so the batch stays retryable and the
pump halts. Refusing is business logic in Natural — the thing a replication product
writing straight into Adabas cannot do.

⚠️ **Plates are matched on `REG-NUM`, and `SOURCE_ISN` is advisory.** The design said the
ISN was the lineage key (ROP: never reused), and within one database it is. But it is
assigned at STORE, so it differs between environments — in this lab the same plate is ISN
806 while Oracle's seed, snapshotted from the migration lab, says 807. A `GET` on the
recorded ISN fails with NAT3113, or in production silently updates whatever record holds
that ISN. A plate number with no matching record is a **new registration** and is stored;
under the no-delete rule a plate is never renamed in place.

## Invariants — breaking these corrupts data silently

- **`_COMPLETE` is written last**, in both `outbox/` and `inbox/`. It is the commit point
  of the file protocol; a directory without it is not ready to read.
- **The producer never deletes a batch.** The consumer acknowledges by renaming the
  directory into `applied/` or `rejected/`.
- **The pump HALTS on the first failure — it must never skip to the next batch.** The
  ledger refuses any batch not newer than its watermark, so applying N+1 after N failed
  moves the watermark past N and N can then *never* be applied: a permanent, silent gap.
  Ordered delivery requires halting, not skipping.
- **Batch numbers must keep rising across restarts.** `BatchWriter` derives the next one
  by scanning `outbox/`, `applied/` and `rejected/`; emptying those without also resetting
  the ledger makes every new batch look already-applied.
- **`op=U` is a full-state upsert, never a diff**, and **child sets are complete**. No
  child rows for a parent means the set is now *empty*, not "unchanged" — which is why
  `BatchWriter` writes every known file **header-only** when it has no rows. Omitting the
  file instead breaks every insert (a new fine may have no payments yet).
- **`occurrence_index` is renumbered 1..n contiguously.** Oracle `LINE_NO`/`SEQ_NO` may
  have gaps after deletes; Adabas occurrences must be dense.
- **The ledger is written in the same Adabas `ET` as the data change**, so "applied but
  not recorded" cannot happen. Keep any new apply path inside that transaction.
- **A refusal must not advance the watermark.** `op=D` is refused, and the ledger is left
  where it was — marking a batch done that was never applied would make it unretryable,
  which is the same permanent silent gap the pump's halt-on-failure rule exists to prevent.
- **Loop prevention is two-layer**: originator filter at capture (efficiency — echoes
  never cost a round trip) plus compare-before-write at apply (safety — it terminates a
  loop even if the filter is misconfigured). Keep both; the no-op counter is the
  filter-leak health metric.

## The MU/PE trap

The sharpest correctness issue in the repo, and why the `SPIKE*` programs are kept even
though nothing invokes them:

- **Lowering an occurrence count does not remove the trailing occurrences.** They survive
  as stale residue *and the count stays put*. `RESET <field>(n+1:max)` **before** lowering
  the count.
- **A periodic group is worse.** An occurrence stays alive while *any* field in it holds
  data — **including fields this sync never maps**. `APPLYFIN` therefore resets all three
  `PAYMENT` fields for removed occurrences, not just the one being inspected. Adding a
  field to the group without resetting it would reintroduce the bug, so removing a field
  from the mapping is a *correctness* change on this leg, not a cosmetic one.
  (The employee aggregate had the nastier version of this: `BONUS`, an MU nested inside
  the `INCOME` PE, was never mapped to Oracle at all and kept occurrences alive on its
  own. Every field of the current PE is mapped, so that cannot happen here — today.)

`natural/SPIKEMU.NSP` demonstrates the failure in isolation; `TESTING_GUIDE.md` has an
experiment that breaks it on purpose.

## Change these together

- **A fixed-width layout** → `CHANGE_FILE_CONTRACT.md` (the offset table *is* the spec)
  + the Hop pipeline that pads the fields + the `READ WORK FILE` structure in
  `APPLYFIN.NSP`. Offsets are absolute: changing one field width shifts everything after
  it. A wrong layout must fail loudly rather than shift values sideways — that is the
  whole reason this leg is fixed-width and not CSV.
- **A new aggregate or table** → `capture.properties` `table.include.list` +
  `AggregateDef` (both `all()` and `BY_TABLE` — `all()` is what puts the file in a batch)
  + `AggregateResolver` + a Hop pipeline + `sync-apply.hwf` + a Natural apply program +
  the work-file list in `natural/run-apply.sh` + `CHANGE_FILE_CONTRACT.md`. Miss the last
  four and the data is captured and then dropped - which is why VEHICLE is defined but
  left out of `all()` and `table.include.list` until its applier exists.
- **`capture/src/main/resources/capture.properties` and `capture/capture-local.properties`
  are duplicates** — the packaged default and the host-run copy. Edit both, or the jar and
  the local run diverge.
- **Target schema** → `oracle-init/01_schema.sql` *and* `04_seed.sql` (the post-migration
  demo snapshot that lets this lab run without the sibling repo). ⚠️ `01_schema.sql` and
  `02_lookups.sql` are **byte-identical copies** of the sibling repo's files — copied, not
  re-derived, so the two labs cannot drift apart in the model. Re-copy them rather than
  editing here, and regenerate `04_seed.sql` by dumping a migrated `a2o-oracle`.
- **BOTH databases need seeding, and they must agree.** Oracle gets `04_seed.sql` on first
  container start; Adabas gets `scripts/seed-source.ps1` (run by `lab-up.ps1`), which adds
  the VIN/type/fuel fields to file 12, creates file 20 with ADAFDU and fills both
  deterministically. The Adabas seed is what the Oracle seed was dumped from, so changing
  one without the other makes every record look like a pending change.
- `oracle-init/` runs **only on first container start**; schema changes need
  `docker compose down -v` or manual DDL. `03_cdc_setup.sql` is the exception —
  `setup-cdc.ps1` applies it to an already-running container.

## Traps that have already cost time

Each has a comment at the site explaining it; don't tidy the comment away.

- **`ORACLE_HOST` in `hop/project-config.json` must stay `oracle`.** Hop *project
  variables override OS environment variables*, so a host-friendly `localhost` there
  silently defeats compose and every container run dies with ORA-12541. The host GUI
  overrides it via the `local-gui` **environment** — the only layer that wins.
- **Hop REST endpoints are `execPipeline` / `execWorkflow`**, not `executePipeline` /
  `executeWorkflow`. The wrong name 404s with a bare Jetty page instead of a Hop
  `<webresult>`, so it looks like a server fault.
- **Hop server mode is selected by the *absence* of `HOP_FILE_PATH`/`HOP_COMMAND`** — there
  is no explicit mode switch. Setting either turns the server into a one-shot runner.
- **Hop Server, not `hop-run` per batch**: 0.4 s warm against 23 s cold, measured. The
  end-to-end budget is 5–10 s, so a JVM per batch would spend multiples of the budget on
  startup.
- **`hop/lib/ojdbc11.jar` is not in the repo** (Oracle OTN) and is bind-mounted as a
  *file*. If missing, Docker creates a **directory** with that name and Hop fails
  obscurely. `sync-verify.cmd` preflights both cases; keep that check.
- **The acknowledgement rename happens on the host, not in the container.** Docker
  Desktop's Windows bind mount refuses a directory rename from inside a container
  (`mv: Permission denied`) regardless of permissions. On real Linux the applier would do
  it itself; the split is safe because re-applying is a no-op by construction.
- **Natural CE has no batch mode.** The applier runs the interactive driver headlessly
  with a stacked command list: no terminal `WRITE` (blocks on the `MORE` prompt),
  `madio=0` (NAT1009 after 512 DB calls), and a unique `etid=A$$` per run. ⚠️ That unique
  ETID means **the applier has no stable ETID identity** — an Adabas-side originator
  filter keyed on ETID would break if the return leg is ever built.
- **DDMs must be catalogued**; CE has no SYSDDM, so `run-apply.sh` re-runs
  `READ LEDGER;CATALOG` every time to self-heal.
- **Adabas writes a host-bound lock** (`/data/db001/_DB_LOCK`). Compose pins
  `hostname: o2a-adabas`; an unclean stop leaves a stale lock and the container then exits
  0 looking healthy. That is what `lab-up.ps1` clears.
- **`ARCHIVELOG` fills the disk.** There is no `rman` in `gvenzl/oracle-free:23-slim`, so
  archive logs go to a plain directory rather than the FRA and nothing reclaims them. Run
  `scripts/purge-archivelogs.sh` periodically.
- **Cold capture needs ~25 s** to mine the data dictionary before it can emit anything;
  `sync-start.cmd` and the verify harness both wait for that. A change made in Oracle
  sooner looks like a lost change and is not one.
- **Ports 60001, 8190, 2700, 1521, 8081** overlap the sibling lab (all but 8081). One lab
  at a time.
- **Line endings are load-bearing.** `.gitattributes` keeps `.sh`/`.NSP`/`.NSD`/`.hpl` at
  LF (they run inside Linux containers; Natural source is column-sensitive) and
  `.cmd`/`.ps1` at CRLF.

## Conventions

- Orchestration is `.cmd` + PowerShell on the host; anything inside a container is `sh`.
- Scripts fail loudly and the entry points abort on the first failing stage.
- `specs/oracle-to-adabas-sync.md` is the design of record — decisions D1–D8, the six
  gating spikes and their results, and the open items. Check a decision there before
  reversing it; the reasoning is usually load-bearing.
- `specs/sync-observability.md` is a **design, not built code**. Nothing in this lab
  alerts: a halted pump is silent and stays silent. Don't cite it as a shipped feature.
- Comments here explain *why*, usually a bug paid for once. Match that density.
- **Never commit** CE binaries, the built `capture/target/` jar, `sync/` runtime state, or
  the Oracle JDBC jar. Adabas & Natural CE are licensed for personal use and learning
  only — the repo is Apache-2.0 and must stay free of CE-derived material beyond the
  documented `04_seed.sql` snapshot.
