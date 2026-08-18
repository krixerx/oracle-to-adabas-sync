# Change file contract — Oracle → Adabas sync

The interface between the open-systems side and the mainframe side.
**Any change here is a breaking change.** Companion to `FLAT_FILE_CONTRACT.md`
in the sibling `adabas-to-oracle-migration` repo, which covers the opposite
direction.

---

## Two legs, two formats

| Leg | Directory | Format | Producer | Consumer |
|---|---|---|---|---|
| capture → mapping | `sync/outbox/batch-NNNNNN/` | **CSV** | `oracle-capture` | Hop Server |
| mapping → apply | `sync/inbox/batch-NNNNNN/` | **fixed-width** | Hop Server | `APPLYFIN`, `APPLYVEH` |

The split is deliberate (open decision O3, decided 2026-08-10). Hop reads CSV natively,
so the capture leg keeps symmetry with the migration lab. Natural's `READ WORK FILE <structure>`
parses **fixed-width positionally for free** — no delimiter, quoting, or
empty-field-vs-NULL handling to get wrong in the leg that writes to the production
database. A wrong fixed-width layout fails loudly; a mis-parsed CSV shifts a value into
the neighbouring field and says nothing.

---

## Batch directory lifecycle

```
sync/outbox/batch-000042/     produced by capture
    manifest.json             written FIRST
    traffic_fine.csv
    traffic_fine_offence.csv
    traffic_fine_payment.csv
    vehicle.csv
    vehicle_plate.csv
    _COMPLETE                 written LAST

sync/inbox/batch-000042/      produced by Hop (same batch number)
    traffic_fine.dat
    traffic_fine_offence.dat
    traffic_fine_payment.dat
    vehicle.dat
    vehicle_plate.dat
    batch_info.dat
    _COMPLETE                 written LAST

sync/applied/batch-000042/    acknowledgement: atomic directory rename
sync/rejected/batch-000042/   conflict or validation failure
```

Two rules make files a real queue rather than a hopeful one:

1. **`_COMPLETE` is written last.** It is the commit point of the file protocol.
   A consumer ignores any directory without it, so a half-written batch can never be read.
2. **The producer never deletes a batch.** The consumer acknowledges by renaming the
   directory into `applied/` or `rejected/`, which is atomic on one filesystem.

Batch numbers increase monotonically and are never reused. The applier refuses any batch
whose number is not greater than the ledger watermark, so ordering violations fail closed.

## Nothing is ever deleted

Revising decision O4 (2026-08-18). Traffic data cannot simply be removed, and both
aggregates already express removal without destroying anything:

- a **fine** is *cancelled* — `status_code = 'C'` — which travels as an ordinary update;
- a **registration** *expires* — `PLATE-EXPIRY`, numeric YYYYMMDD, `00000000` while current.

So `op=D` has no legitimate meaning on this leg. Both appliers **refuse** it, report
`REFUSED-DELETE`, and **do not advance the ledger watermark** — the batch was not applied,
so marking it done would make it unretryable. The pump then halts and a human decides.
That refusal is business logic living in Natural, which is exactly what a replication
product writing straight into Adabas would bypass.

---

## Capture leg — CSV rules

- BOM-less UTF-8, comma-delimited, one header row, RFC 4180 quoting.
- Empty field = NULL.
- Every parent row carries `op` (`U` = upsert full state, `D` = delete) and `tx_seq`
  (commit order within the batch — apply ascending).
- Child rows carry `parent_key` (the business key of the owning parent) and
  `occurrence_index`, **renumbered 1..n contiguously**. Oracle's `SEQ_NO` / `PLATE_SEQ`
  may have gaps after deletes; Adabas occurrences must be dense.
- **Child sets are complete.** For a parent with `op=U`, the child rows present in the
  batch are *all* the occurrences. No child rows for that parent means the set is now
  **empty** — not "unchanged".
- **Dates arrive as `YYYYMMDD` text and amounts as text with an explicit decimal point**
  (`85.00`). Both are rendered by the capture SQL, not by Hop: Adabas stores the date
  numerically and the amount as packed `P7.2`, so the text form has to be exact. Keeping
  the amount textual end to end also keeps the server locale out of the path — a comma
  decimal separator reaching Natural's `VAL()` would silently become a different amount.

### `manifest.json`

```json
{
  "batch"        : 42,
  "created_utc"  : "2026-08-18T06:46:04.932Z",
  "start_scn"    : "3280777",
  "end_scn"      : "3280777",
  "transactions" : 1,
  "row_counts"   : { "traffic_fine": 1, "traffic_fine_offence": 2,
                     "traffic_fine_payment": 0, "vehicle": 0, "vehicle_plate": 0 }
}
```

`end_scn` becomes `LAST-SCN` in the Adabas ledger — the restart watermark.

---

## Apply leg — fixed-width layouts

Fields are space-padded on the right (alphanumeric) or zero-padded on the left (numeric).
No delimiters, no header row, one record per line, LF-terminated, UTF-8.

Offsets are **absolute**: changing one field width shifts everything after it, so the
layout table, the Hop output field lengths and the `READ WORK FILE` structure in
`APPLYFIN.NSP` must be changed together.

### `traffic_fine.dat` — 81 bytes  ·  Adabas file 20

| Offset | Len | Field | Adabas | Notes |
|---:|---:|---|---|---|
| 1 | 1 | `op` | — | `U` or `D` |
| 2 | 10 | `fine_no` | `FINE-NO` A10 | business key, `DE,UQ` |
| 12 | 15 | `plate_no` | `PLATE-NO` A15 | as recorded, suffix and all |
| 27 | 8 | `offence_date` | `OFFENCE-DATE` N8 | `YYYYMMDD` text → `VAL()` |
| 35 | 30 | `location` | `LOCATION` A30 | |
| 65 | 8 | `amount` | `AMOUNT` P7.2 | text with decimal point, e.g. `85.00` → `VAL()` |
| 73 | 1 | `status_adabas` | `STATUS` A1 | **code**, reversed from the description by Hop |
| 74 | 8 | `offender_national_id` | `OFFENDER-ID` A8 | |

For `op=D` only `op` and `fine_no` are meaningful; the rest is space-filled.

### `traffic_fine_offence.dat` — 17 bytes  ·  MU

| Offset | Len | Field | Adabas |
|---:|---:|---|---|
| 1 | 10 | `parent_key` | the fine's `FINE-NO` |
| 11 | 3 | `occurrence_index` | N, zero-padded |
| 14 | 4 | `offence_adabas` | `OFFENCE-CODE(i)` A4, reversed from the description |

### `traffic_fine_payment.dat` — 31 bytes  ·  PE

| Offset | Len | Field | Adabas |
|---:|---:|---|---|
| 1 | 10 | `parent_key` | the fine's `FINE-NO` |
| 11 | 3 | `occurrence_index` | N, zero-padded |
| 14 | 8 | `paid_date` | `PAY-DATE(i)` N8, `YYYYMMDD` text |
| 22 | 8 | `paid_amount` | `PAY-AMT(i)` P7.2, text with decimal point |
| 30 | 2 | `method_adabas` | `PAY-METH(i)` A2, reversed from the description |

### `vehicle.dat` — 108 bytes  ·  Adabas file 12

| Offset | Len | Field | Adabas | Notes |
|---:|---:|---|---|---|
| 1 | 1 | `op` | — | `U`; `D` is refused |
| 2 | 17 | `vin` | — | **base** VIN, the aggregate key. NOT written to Adabas |
| 19 | 8 | `owner_national_id` | `PERSONNEL-ID` A8 | |
| 27 | 20 | `make` | `MAKE` A20 | |
| 47 | 20 | `model` | `MODEL` A20 | |
| 67 | 10 | `color` | `COLOR` A10 | |
| 77 | 4 | `year_built` | `YEAR` U4 | zero-padded |
| 81 | 8 | `veh_type_adabas` | `VEH-TYPE` A8 | legacy code — **lineage first**, reverse map only as fallback |
| 89 | 20 | `source_fuel_desc` | `FUEL-DESC` A20 | free text, verbatim |

⚠️ **`VIN` is never written back.** Adabas stores base+suffix (A25) and Oracle knows only
the 17-character base; the suffix encodes "another plate for this car" and belongs to the
Adabas record. Writing the base VIN back would destroy it.

### `vehicle_plate.dat` — 53 bytes  ·  one row = one Adabas RECORD

| Offset | Len | Field | Adabas |
|---:|---:|---|---|
| 1 | 17 | `parent_key` | the vehicle's base VIN |
| 18 | 3 | `occurrence_index` | N, zero-padded — plate 1..3 |
| 21 | 15 | `plate_no` | `REG-NUM` A15 — **the match key**, `DE,UQ` |
| 36 | 10 | `source_isn` | lineage/evidence only, **advisory** |
| 46 | 8 | `expiry_date` | `PLATE-EXPIRY` U8, `00000000` = still current |

⚠️ **This file is not an MU/PE set — it is a set of RECORDS.** Adabas file 12 holds one
record per plate, so an Oracle vehicle with three plates is three Adabas records, each
repeating the vehicle's own attributes.

⚠️ **Matched on `plate_no`, not `source_isn`.** ISNs are never reused *within one
database*, but they are assigned at STORE and therefore differ between environments: the
same plate is ISN 806 in this lab and 807 in the migration lab it was seeded from. A GET
on the recorded ISN fails outright — or, worse in production, updates whatever record
happens to hold that ISN. `REG-NUM` is a unique descriptor and cannot drift, so it is the
key; the ISN is carried as evidence. A plate number with no matching record is a **new
registration** and is stored, because under the no-delete rule a plate is never renamed in
place.

### `batch_info.dat` — 21 bytes

| Offset | Len | Field | Type |
|---:|---:|---|---|
| 1 | 6 | `batch_no` | N, zero-padded |
| 7 | 15 | `end_scn` | N, zero-padded |

`end_scn` is 15 digits because Oracle SCNs outgrow a 4-byte integer; the ledger field is
packed 15 and was tested at `999999999999999` (spike S5).

---

## Field mapping performed by Hop (C5)

The reverse of the migration lab, using the **same** `CODE_LOOKUP` table:

| Concern | Direction |
|---|---|
| `STATUS` | description → code (`'Appealed'` → `'A'`), domain `FINE_STATUS` |
| `OFFENCE_DESC` | description → code (`'Illegal parking'` → `'PARK'`), domain `OFFENCE` |
| `METHOD` | description → code (`'Bank transfer'` → `'BT'`), domain `PAY_METHOD` |
| `VEHICLE_TYPE_CODE` | standard → legacy code via `VEHICLE_TYPE_MAP` — **fallback only**, see below |
| dates, amounts | already textual from the capture SQL — Hop only pads them |
| numeric padding | left-zero-pad `occurrence_index`, `batch_no`, `end_scn` |
| string padding | right-space-pad to the layout width, truncate to Adabas field length |

**Why reverse the description at all, when Oracle already stores the code?** The model
keeps both (`status` + `status_code`), so the code could simply be copied. Resolving the
description independently is what a real synchroniser does — the description is the value
a user edits — and it makes a drift between the two visible instead of silently writing
whichever one happened to be picked.

**The vehicle type reversal is lossy and must not be trusted.** SEDAN, ESTATE and HATCH
all map to `PC`, so `PC` does not identify the code it came from. The migration kept the
original in `source_vehicle_type` precisely so the round trip need not guess: that column
is authoritative and exact, and the reverse map is consulted **only** when there is no
lineage value — a vehicle created in Oracle that never had a legacy code. Letting the map
win over a known original would silently rewrite SEDAN as ESTATE.

### Deliberately NOT carried to Adabas

Columns the migration *derived* have no field in the source: `POWERTRAIN_CODE`,
`POWERTRAIN_SOURCE` (computed from the VIN or the fuel text) and `VEHICLE_ID` on a fine
(Adabas records the plate the camera read, never the vehicle). A change to one of them
still triggers a re-read, and the applier then finds Adabas already in the desired state
and reports `NOOP-IDENTICAL` — the correct outcome, not a missed change.

⚠️ Do not confuse this with the MU/PE rule, which points the other way: an unmapped field
*inside a periodic group* keeps an occurrence alive and must still be `RESET`. An
Oracle-only column has no Adabas counterpart at all and is simply dropped.

> **Truncation is a real risk, not a formality.** Oracle columns are wider than their
> Adabas counterparts (`LOCATION VARCHAR2(30)` happens to match, but
> `PLATE_NO VARCHAR2(15)` and `OFFENCE_CODE VARCHAR2(4)` are exact-fit and leave no
> headroom). Hop truncates to the Adabas width; anything longer would otherwise shift
> every following field and corrupt the record silently. Test 4 in the spec's success
> criteria covers the MU case; a long-value case belongs in round 3 alongside encoding.
