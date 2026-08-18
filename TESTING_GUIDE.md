# Oracle → Adabas Sync — Hands-On Testing & Learning Guide

How to run the sync, take it apart stage by stage, watch a single change travel from an
Oracle `COMMIT` into an Adabas record, and break it on purpose.

Companion to the `TESTING_GUIDE.md` of the sibling repo `adabas-to-oracle-migration`,
which covers the other direction. Everything here happens in this repository's root —
open a terminal there first.

> **The one-sentence version:** Oracle writes a change to its redo log; we tail the log,
> re-read the whole affected record from Oracle, write it to a file, let Hop rename the
> fields, and let a Natural program write it into Adabas through the normal business logic.

---

## 1. Quick start — run the whole acceptance suite

```bat
sync-verify.cmd
```

Prerequisite: **Docker Desktop running**, and `scripts\setup-cdc.ps1` run once ever
(§8 explains what it does).

Takes ~6–8 minutes. It makes real changes in Oracle, syncs them, and asserts on Adabas.
Success looks like:

```
  PASS   1. scalar update propagates
  ...
  PASS   9. Adabas outage: changes queue and drain
  SKIP  10. conflict detected and routed to rejected/
        out of scope this round (spec 5.4)
  PASS  11. vehicle: attribute hits every plate record, expiry one

SYNC VERIFIED: 10/11   (1 skipped by design)
```

**10/11 is the expected, correct result, and the suite exits 0.** Criterion 10 is conflict
detection, deferred to round 3 by decision (spec O2, design in 5.4). It is reported as
SKIP rather than FAIL so the printed result and the exit code agree. Everything built is
passing.

---

## 2. The pipeline, one stage at a time

This is the part worth your time. The suite runs everything at once; here you drive each
stage by hand and look at what it produced.

```
   Oracle          capture           files            Hop Server        Natural         Adabas
  COMMIT  ──▶  redo → Debezium  ──▶  outbox/  ──▶  reverse mapping ──▶  inbox/  ──▶  APPLYFIN  ──▶  file 20
                                     (CSV)          (fixed-width)                    + ledger 99
```

### Stage 0 — bring the lab up

```bat
powershell -File scripts\lab-up.ps1
docker compose --profile sync up -d hop-server
```

`lab-up.ps1` also clears the stale Adabas lock that a hard shutdown leaves behind — the
single most common reason the lab "starts" but Adabas is actually dead (§9).

### Stage 1 — start the capture service and watch it idle

```bat
java -jar capture\target\oracle-capture.jar capture\capture-local.properties
```

Leave it running in its own window. After ~25 s of dictionary mining you'll see:

```
=== Oracle to Adabas sync - Oracle capture ===
  source     : localhost/FREE pdb=FREEPDB1
  outbox     : ...\sync\outbox
  flush      : every 5000 ms
  filtering  : changes made by SYNCAPP (loop prevention)
  next batch : batch-000001
```

Nothing else happens until something changes in Oracle. That silence is the point: it is
reading the log, not asking the tables anything.

### Stage 2 — make a change in Oracle and watch a batch appear

In a second terminal:

```bat
docker exec -it o2a-oracle sqlplus pocapp/pocapp@//localhost:1521/FREEPDB1
```

```sql
UPDATE pocapp.traffic_fine SET location = 'LEARNING' WHERE fine_no = 'F000000005';
COMMIT;
```

Within ~5–10 s the capture window prints:

```
  wrote batch-000001  rows=3 transactions=1 scn=3280777..3280777
```

**Note `rows=3` from a one-column update** (the exact number depends on how many
occurrences that fine currently has: 1 parent + its offence codes + its payments).
That is decision D4 working: we don't ship the delta, we re-read the *whole fine
aggregate*. Look at it:

```bat
dir sync\outbox\batch-000001
type sync\outbox\batch-000001\traffic_fine.csv
type sync\outbox\batch-000001\traffic_fine_offence.csv
type sync\outbox\batch-000001\manifest.json
```

Things to notice:

- `_COMPLETE` is the last file written. A reader ignores any batch directory without it —
  that's what stops anyone reading a half-written batch.
- `traffic_fine_offence.csv` has `occurrence_index` 1,2 **contiguous**, whatever the
  `SEQ_NO` values in Oracle happen to be. Adabas occurrences must be dense.
- `traffic_fine_payment.csv` is present **with only a header** when the fine has no
  payments. That is not an omission: an empty child file means "the set is now empty",
  which is different from "unchanged".
- `manifest.json` carries `start_scn`/`end_scn` — the restart watermark.
- `status` is still the *description* (`Appealed`), and `amount` is text with a decimal
  point (`85.00`). Hop reverses the description next.

### Stage 3 — run the reverse mapping by hand

```bat
curl -u cluster:cluster "http://localhost:8081/hop/execWorkflow/?workflow=/poc/hop/workflows/sync-apply.hwf&runConfig=local&level=Basic&BATCH_IN=/sync/outbox/batch-000001&BATCH_OUT=/sync/inbox/batch-000001"
```

Expect `<result>OK</result>`. Now compare the two formats:

```bat
type sync\outbox\batch-000001\traffic_fine.csv     :: CSV, human-friendly
type sync\inbox\batch-000001\traffic_fine.dat      :: fixed-width, mainframe-friendly
```

The `.dat` line is exactly 81 characters, no delimiters. Count to position 73 and you'll
find `A` where the CSV said `Appealed` — that's the reverse `CODE_LOOKUP`, the same table
the migration lab used in the forward direction. The MU file does the same trick:
`traffic_fine_offence.dat` carries `SPD2`, not "Speeding, more than 20 km/h over the
limit".

> **Why two formats?** Natural's `READ WORK FILE <structure>` parses fixed-width
> positionally for free. Parsing CSV in Natural means hand-writing delimiter, quoting and
> empty-field logic in the leg that writes to the production database. A wrong fixed-width
> layout fails loudly; a mis-parsed CSV shifts a value into the next field and says
> nothing. (Spec decision O3.)

### Stage 4 — apply it to Adabas

The applier needs `batch_info.dat` (batch number + end SCN) and the `_COMPLETE` marker.
The pump writes both automatically; by hand:

```bat
powershell -File scripts\make-batch-info.ps1 batch-000001
docker exec o2a-natural sh /poc/natural/run-apply.sh batch-000001
```

```
UPDATED F000000005
SUMMARY batch= 1 stored= 0 updated= 1 skipped= 0 deleted= 0
```

### Stage 5 — look at the Adabas record

```bat
docker exec o2a-natural sh /poc/natural/run-dump.sh F000000005
```

`LOC=LEARNING`. The change has crossed from Oracle to the mainframe side.

`DUMPFIN` deliberately prints **six** occurrences of each MU/PE regardless of the count
field, so you can see whether removed occurrences are really gone or merely uncounted —
which is exactly the bug class §6 is about.

### Stage 6 — let the pump do stages 3–5 for you

```bat
powershell -File scripts\sync-pump.ps1          :: process every ready batch once
powershell -File scripts\sync-pump.ps1 -Watch   :: keep polling
```

With `-Watch` running in one window and the capture service in another, you have a live
sync: type an `UPDATE` in sqlplus, and a few seconds later the Adabas record changes.
That is the demo worth showing people.

---

## 3. Key files — where everything lives

| Path | What it is | When you touch it |
|---|---|---|
| `sync-verify.cmd` | The acceptance suite (ten criteria) | Every run |
| `scripts\sync-verify.ps1` | The tests themselves — readable, one block each | To add a test |
| `scripts\sync-pump.ps1` | Drives batches: map → apply → acknowledge | To change orchestration |
| `scripts\make-batch-info.ps1` | Writes `batch_info.dat` + `_COMPLETE` for a hand-run batch | Only when running stages by hand |
| `capture\src\...\Assembler.java` | Originator filter, transaction buffer, change rows | **The interesting logic** |
| `capture\src\...\AggregateDef.java` | **Which Oracle tables form one Adabas record** | To add an aggregate |
| `capture\src\...\AggregateResolver.java` | The re-read SQL (decision D4) | To change what's fetched |
| `capture\src\...\BatchWriter.java` | Batch directories, `_COMPLETE`, manifest | Rarely |
| `capture\capture-local.properties` | Connection, **`table.include.list`**, flush interval | To change scope |
| `hop\pipelines\60_sync_traffic_fine.hpl` | Parent reverse mapping + code reversal | **Where mappings live** |
| `hop\pipelines\7*_sync_*.hpl` | Child (MU/PE) reverse mappings | Same |
| `hop\workflows\sync-apply.hwf` | Runs the three pipelines for one batch | If you add a shape |
| `natural\APPLYFIN.NSP` | **The apply API** — upsert, delete, MU/PE replacement, ledger | **The other interesting logic** |
| `natural\DUMPFIN.NSP` | Read-only dump used by the tests to assert on Adabas | To assert on more fields |
| `natural\RESETLED.NSP` | Clears the watermark — **test support only** | Between test runs |
| `natural\LEDGER.fdt/.fdu/.NSD` | Adabas file 99 definition + DDM | Rarely |
| `sync\` | Runtime: `outbox inbox applied rejected state` | Look, don't edit |
| `CHANGE_FILE_CONTRACT.md` | The file interface — layouts and rules | Read once |
| `specs\POC2_Oracle_to_Adabas_Sync.md` | The design and all decisions | Read once |

---

## 4. Reading the three logs

| Where | Shows | Useful line |
|---|---|---|
| capture window / `sync\capture.log` | batches written, echoes filtered | `wrote batch-000007 rows=9 transactions=2` |
| pump output | mapping + apply per batch | `ACK batch-000007 -> applied/` |
| `docker logs o2a-hop-server` | Hop pipeline detail | transform row counts |

Two counters worth watching:

- **`echoes filtered: N`** (printed when capture stops) — changes dropped because
  `SYNCAPP` made them. Loop prevention doing its job.
- **`skipped=N`** in an apply summary — records already in the desired state.
  In steady state this should be near zero; a rising number means the originator filter
  is leaking and the safety net is catching it.

---

## 5. Where the mappings are defined

Two halves, two places — worth being explicit because it's the question that started this
design:

| Concern | Lives in | Example |
|---|---|---|
| Which Oracle tables form one Adabas record | `AggregateDef.java` | `TRAFFIC_FINE` + 2 children → file 20 |
| Which SQL fetches it | `AggregateDef.java` (`rootSelectSql`) | the `TO_CHAR(OFFENCE_DATE,'YYYYMMDD')` lives here |
| Field names, widths, code reversal | **Hop `.hpl`** | `'Appealed'` → `'A'` |
| Adabas field/occurrence semantics | `APPLYFIN.NSP` | `C*OFFENCE-CODE`, `RESET OFFENCE-CODE(3:20)` |

To see the Hop half on a canvas, open the Hop GUI (`hop-gui-o2a.cmd`) and open
`pipelines\60_sync_traffic_fine.hpl`. **Preview** on the lookup transform is the clearest
possible demonstration of the code reversal.

---

## 6. Experiments to try

Easiest first. Run the capture service and `sync-pump.ps1 -Watch` in two windows, then
type SQL in a third.

**a) Watch a scalar change travel.**
```sql
UPDATE pocapp.traffic_fine SET location = 'ROUNDABOUT 7' WHERE fine_no = 'F000000005';
COMMIT;
```
Then `run-dump.sh F000000005`. Time it — you should see 5–10 s.

**b) See a delete, which polling could never see.**
```sql
DELETE FROM pocapp.traffic_fine_offence
 WHERE fine_id = (SELECT fine_id FROM pocapp.traffic_fine WHERE fine_no='F000000005')
   AND seq_no = (SELECT MAX(seq_no) FROM pocapp.traffic_fine_offence
                  WHERE fine_id = (SELECT fine_id FROM pocapp.traffic_fine WHERE fine_no='F000000005'));
COMMIT;
```
Watch `COFF` drop by one *and* the vacated occurrence come back empty in the dump. A
`LAST_MODIFIED`-column poller would never have noticed this row leaving.

**c) Prove loop prevention with your own hands.**
```bat
docker exec -it o2a-oracle sqlplus syncapp/syncapp@//localhost:1521/FREEPDB1
```
```sql
UPDATE pocapp.traffic_fine SET location = 'SHOULD-NOT-TRAVEL' WHERE fine_no = 'F000000005';
COMMIT;
```
No batch appears. Stop the capture service and it reports `echoes filtered: 1`. This is
the entire loop-prevention mechanism, and it is stateless — no ledger, no timing window.

**d) Prove replay is safe.**
```bat
docker exec o2a-natural sh /poc/natural/run-reset-ledger.sh
move sync\applied\batch-000001 sync\inbox\
docker exec o2a-natural sh /poc/natural/run-apply.sh batch-000001
```
`NOOP-IDENTICAL` — the record is already in the desired state, so nothing is written. The
ledger guard is deliberately reset first so you're seeing compare-before-write itself,
not the watermark short-circuit.

**e) Break the MU/PE shrink on purpose — the best lesson here.**
In `natural\APPLYFIN.NSP`, comment out one `RESET` line in `MOVE-FIELDS`:
```natural
*  RESET OFFENCE-CODE(#OFF-CNT + 1:20)   <-- comment this out
   C*OFFENCE-CODE := #OFF-CNT
```
Then delete some offence rows in Oracle and sync. The count drops, but `run-dump.sh` shows
the old values **still sitting there** beyond the count. No error anywhere. Put the line
back. This is the trap that spike S4 exists to document, and seeing it once is worth more
than reading about it.

**f) Break ordering on purpose.** Stop the pump. Make three separate changes (commit
each). You now have three batches. Delete the *middle* one from `sync\outbox\` and run the
pump: it applies the first, then halts at the gap rather than skipping ahead — because
applying batch 3 would move the watermark past batch 2 forever.

**g) Add a field to the sync.** `TRAFFIC_FINE.OFFENDER_NATIONAL_ID` is already carried; try adding
something not currently mapped. You'll touch all four layers: `AggregateDef` (SQL +
column list), the contract layout, the Hop pipeline (input field + output field with a
width), and `APPLYFIN` (record layout + `MOVE-FIELDS` + `COMPARE-RECORD`). Doing this once
teaches the shape of the whole system.

---

## 7. Inspecting both databases

**Oracle** (same as the migration lab):
```bat
docker exec -it o2a-oracle sqlplus pocapp/pocapp@//localhost:1521/FREEPDB1
```

**Adabas** — via the dump program (no SQL; Adabas isn't relational):
```bat
docker exec o2a-natural sh /poc/natural/run-dump.sh F000000005
```

**The ledger** (Adabas file 99 — how far the sync has got):
```bat
docker exec o2a-natural sh /poc/natural/run-apply.sh batch-999999
```
It refuses and tells you the current watermark. A blunt way to read it, but it works
without another program.

**The redo log itself**, if you want to see what Debezium sees — SYSDBA on service `FREE`
(not `FREEPDB1`), both statements in the *same* session, because `V$LOGMNR_CONTENTS` is
session-private:
```sql
EXEC DBMS_LOGMNR.START_LOGMNR(OPTIONS => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG + DBMS_LOGMNR.COMMITTED_DATA_ONLY);
SELECT username, operation, sql_redo FROM v$logmnr_contents
 WHERE seg_owner = 'POCAPP' AND ROWNUM <= 20;
```

---

## 8. What `setup-cdc.ps1` did (one time, already done)

Worth understanding, because these are the questions a production DBA will be asked:

| Change | Why | Production consideration |
|---|---|---|
| `ARCHIVELOG` mode | LogMiner needs archived redo to survive log switches | Requires a restart cycle and FRA sizing |
| Supplemental logging (min + PK) | Puts real column predicates in the redo instead of ROWIDs | Small redo increase |
| Supplemental logging (**ALL COLUMNS**) | Adds the full before-image — what conflict detection would need | **Raises redo volume on every update.** Negligible in a lab; a real conversation at production scale |
| `C##DBZUSER` + grants | The capture user; needs `LOGMINING`, `CREATE TABLE` (for its flush table) | Least-privilege list is in `03_cdc_setup.sql` |
| `SYNCAPP` | The apply-back user — **the originator filter's target** | Must be the only identity the reverse leg writes as |

Archive logs are purged by `scripts\purge-archivelogs.sh` (by age). **Turning on
ARCHIVELOG without a purge job fills the disk in days** — that's the most likely way this
lab dies quietly.

---

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Adabas container exits 0 right after starting | Stale `_DB_LOCK` in the volume from a hard shutdown. Run `scripts\lab-up.ps1`, which clears it. The exit code being **0** is why this looks like success. |
| Capture starts then dies with ORA-01031 | `C##DBZUSER` missing `CREATE TABLE` (it maintains a `LOG_MINING_FLUSH` table). Re-run `scripts\setup-cdc.ps1`. |
| Capture dies with ORA-41900 | `snapshot.locking.mode=none` missing from `capture.properties`. |
| Batch written but nothing reaches Adabas | Check the pump output. If mapping failed it **halts by design** — fix the cause and re-run; do not skip the batch. |
| Apply says `ALREADY-APPLIED` | The ledger watermark is at or past this batch. Correct behaviour. For a test re-run: `run-reset-ledger.sh`. |
| Everything works but no batches appear | Are you changing the tables in `table.include.list`? Are you connected as `SYNCAPP` (whose writes are filtered by design)? |
| `mv: Permission denied` in the container | Known Docker Desktop bind-mount limit — the pump does the rename from the host instead. Not a bug in the lab. |
| Hop returns 404 | The endpoints are `execPipeline` / `execWorkflow`, not `executePipeline` / `executeWorkflow`. |
| Hop can't reach Oracle | `hop\project-config.json` must keep `ORACLE_HOST = oracle`. **Hop project variables override OS environment variables**, so a host-side value there breaks every container run. Host GUI overrides via the `local-gui` environment instead. |

---

## 10. Suggested plan for a session

1. `sync-verify.cmd` once — see `SYNC VERIFIED: 10/11` end to end (~8 min).
2. Work through §2 stage by stage on one change. This is the core of the learning: you
   see the same record as CSV, as fixed-width, and as an Adabas record.
3. Run capture + `sync-pump.ps1 -Watch` and type a few `UPDATE`s. Watch the latency.
4. Do experiment (c) — loop prevention — then (d) — replay safety. Both are quick and
   both are the properties that make bi-directional sync survivable.
5. Do experiment (e), the MU/PE shrink bug. Break it, see the silent corruption, fix it.
6. If appetite remains: (g), add a field end to end.

Round 3 topics, deliberately not here: conflict detection, dirty data, encoding /
codepages, MU/PE before-images, and the **vehicle aggregate** (only the traffic fine is
wired into the sync so far). The vehicle leg is not just more of the same: Adabas file 12
holds one record *per plate*, so an Oracle vehicle with three plates is three Adabas
records, and writing it back reconciles a set of records rather than occupancy inside one.
