#!/bin/sh
# Turns the sync/ directory tree into Prometheus metrics.
#
# WHY A SCRIPT AND NOT AN EXPORTER LIBRARY: the queue in this design is made of
# DIRECTORIES, and Prometheus cannot see a directory. The conventional answer is
# node_exporter's textfile collector - a script writes a .prom file, the exporter
# serves it. We keep the pattern but skip node_exporter itself: inside a container
# its host metrics describe the container, not the Windows host, so it would ship
# hundreds of useless series to serve our twenty. busybox httpd serves the file.
#
# READ-ONLY BY CONSTRUCTION. /sync is mounted ro (see docker-compose.yml). That is
# deliberate: observability must be an observer, never a dependency, and a process
# that cannot rename a batch directory can never damage the queue it is watching.
# It also sidesteps the Windows bind-mount rename restriction entirely, which was
# open question 1 in the spec.
#
# Writes atomically - temp file plus mv - so httpd never serves half a scrape.
set -u

SYNC="${SYNC_DIR:-/sync}"
OUTFILE="${TEXTFILE:-/textfile/sync.prom}"
INTERVAL="${BUILD_INTERVAL:-10}"

TMP="$OUTFILE.tmp"

emit() { printf '%s\n' "$*" >> "$TMP"; }

# ---------------------------------------------------------------- helpers ---

# Value of key=... from a heartbeat file. Empty when the file or key is absent.
# tr -d strips CR: these files are written by Windows-side processes, and a
# trailing carriage return makes shell arithmetic fail silently, which would
# make the age vanish rather than error.
hb() { [ -f "$1" ] && sed -n "s/^$2=//p" "$1" | head -1 | tr -d '\r'; }

count_dirs() { find "$1" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }

# Only directories carrying _COMPLETE count as queued: the marker IS the commit
# point of the file protocol, so a directory without it is still being written.
count_complete() {
  n=0
  for d in "$1"/batch-*; do
    [ -f "$d/_COMPLETE" ] && n=$((n + 1))
  done
  echo "$n"
}

# Label values must not contain " or \. Reasons come from Natural output so they
# are tame, but one stray quote would make the whole exposition file unparseable
# and silently kill the scrape - every metric here, not just this one.
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9 ._:=/-' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; }

# Sums stored/updated/skipped/refused across every SUMMARY line under a directory.
# Both appliers write one: "SUMMARY batch= 13 stored= 0 ..." (fine) and
# "SUMMARY-VEH ... rejected= 0" (vehicle). The space after "=" is how Natural's
# COMPRESS renders it, hence the gsub.
sum_outcomes() {
  find "$1" -maxdepth 2 -name 'apply_result*.txt' -exec cat {} + 2>/dev/null | awk '
    /^SUMMARY/ {
      line = $0; gsub(/= +/, "=", line)
      n = split(line, a, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        split(a[i], kv, "=")
             if (kv[1] == "stored")   stored  += kv[2]
        else if (kv[1] == "updated")  updated += kv[2]
        else if (kv[1] == "skipped")  skipped += kv[2]
        else if (kv[1] == "refused")  refused += kv[2]
        else if (kv[1] == "rejected") refused += kv[2]
      }
    }
    END { printf "%d %d %d %d\n", stored+0, updated+0, skipped+0, refused+0 }
  '
}

# ------------------------------------------------------------- the scrape ---

build() {
  now=$(date +%s)
  : > "$TMP"

  emit "# HELP sync_exporter_scrape_timestamp_seconds When this file was last rebuilt."
  emit "# TYPE sync_exporter_scrape_timestamp_seconds gauge"
  emit "sync_exporter_scrape_timestamp_seconds $now"

  # --- heartbeats: the one thing no other signal can tell us ---------------
  #
  # Nothing else distinguishes STOPPED from IDLE. An idle pump and a killed pump
  # both show an empty queue and no activity; only a heartbeat that stops
  # advancing separates them. That is why this is the highest-value metric in the
  # file and the one the most important alert rule reads.
  #
  # Emitted only once the file exists, so a lab that has never run the pump does
  # not alert. Age is clamped at zero: a WSL2 container clock can drift behind the
  # Windows host across a sleep/resume, which would otherwise read as negative.
  for role in pump capture; do
    f="$SYNC/state/$role.heartbeat"
    [ -f "$f" ] || continue
    epoch=$(hb "$f" epoch)
    [ -n "$epoch" ] || epoch=$(stat -c %Y "$f" 2>/dev/null || echo "$now")
    age=$((now - epoch))
    [ "$age" -lt 0 ] && age=0
    emit "# HELP sync_${role}_heartbeat_age_seconds Seconds since the $role last reported alive."
    emit "# TYPE sync_${role}_heartbeat_age_seconds gauge"
    emit "sync_${role}_heartbeat_age_seconds $age"
  done

  # The pump KNOWS when it has halted, so it says so directly. Inferring it from
  # a queue that stopped draining would take ten minutes to become obvious.
  halted=$(hb "$SYNC/state/pump.heartbeat" halted)
  [ -n "$halted" ] || halted=0
  emit "# HELP sync_pump_halted 1 when the pump stopped on a failed batch and is waiting for a human."
  emit "# TYPE sync_pump_halted gauge"
  emit "sync_pump_halted $halted"

  if [ "$halted" = "1" ]; then
    halt_batch=$(sanitize "$(hb "$SYNC/state/pump.heartbeat" halt_batch)")
    halt_stage=$(sanitize "$(hb "$SYNC/state/pump.heartbeat" halt_stage)")
    emit "# HELP sync_pump_halt_info Which batch the pump halted on, and at which stage."
    emit "# TYPE sync_pump_halt_info gauge"
    emit "sync_pump_halt_info{batch=\"$halt_batch\",stage=\"$halt_stage\"} 1"
  fi

  echoes=$(hb "$SYNC/state/capture.heartbeat" echoes_filtered)
  if [ -n "$echoes" ]; then
    emit "# HELP sync_capture_echoes_filtered_total Changes made by the sync's own apply user, dropped at capture."
    emit "# TYPE sync_capture_echoes_filtered_total counter"
    emit "sync_capture_echoes_filtered_total $echoes"
  fi

  # --- queue depths --------------------------------------------------------
  outbox=$(count_complete "$SYNC/outbox")
  inbox=$(count_complete "$SYNC/inbox")
  applied=$(count_dirs "$SYNC/applied")
  rejected=$(count_dirs "$SYNC/rejected")

  emit "# HELP sync_batches_outbox Captured batches waiting to be mapped."
  emit "# TYPE sync_batches_outbox gauge"
  emit "sync_batches_outbox $outbox"
  emit "# HELP sync_batches_inbox Mapped batches waiting to be applied to Adabas."
  emit "# TYPE sync_batches_inbox gauge"
  emit "sync_batches_inbox $inbox"
  emit "# HELP sync_batches_pending Batches captured but not yet applied."
  emit "# TYPE sync_batches_pending gauge"
  emit "sync_batches_pending $((outbox + inbox))"
  emit "# HELP sync_batches_rejected Batches that failed to apply and are waiting for a retry."
  emit "# TYPE sync_batches_rejected gauge"
  emit "sync_batches_rejected $rejected"
  # Counter by convention and monotonic in practice - but nothing prunes applied/
  # yet (spec open question 3). If a retention job ever does, this drops, and
  # Prometheus will read the drop as a counter reset.
  emit "# HELP sync_batches_applied_total Batches applied to Adabas successfully."
  emit "# TYPE sync_batches_applied_total counter"
  emit "sync_batches_applied_total $applied"

  # --- what actually reached Adabas ----------------------------------------
  set -- $(sum_outcomes "$SYNC/applied")
  emit "# HELP sync_records_applied_total Records by outcome, summed over every applied batch."
  emit "# TYPE sync_records_applied_total counter"
  emit "sync_records_applied_total{outcome=\"stored\"} $1"
  emit "sync_records_applied_total{outcome=\"updated\"} $2"
  emit "sync_records_applied_total{outcome=\"skipped\"} $3"
  emit "sync_records_applied_total{outcome=\"refused\"} $4"
  # skipped = compare-before-write found Adabas already holding the value. In
  # steady state that is the filter-leak health metric: it should sit near zero.
  emit "# HELP sync_rows_applied_total Records written to Adabas (stored + updated)."
  emit "# TYPE sync_rows_applied_total counter"
  emit "sync_rows_applied_total $(($1 + $2))"

  # --- watermark ------------------------------------------------------------
  last=$(ls "$SYNC/applied" 2>/dev/null | grep '^batch-' | sort | tail -1)
  if [ -n "$last" ]; then
    num=$(echo "$last" | sed 's/^batch-0*//')
    [ -n "$num" ] || num=0
    emit "# HELP sync_last_applied_batch Number of the newest batch in applied/."
    emit "# TYPE sync_last_applied_batch gauge"
    emit "sync_last_applied_batch $num"

    # batch_info.dat is one 21-character line: 6 digits of batch, 15 of end SCN.
    info="$SYNC/applied/$last/batch_info.dat"
    if [ -f "$info" ]; then
      scn=$(head -c 21 "$info" | cut -c7-21 | sed 's/^0*//')
      [ -n "$scn" ] || scn=0
      emit "# HELP sync_last_applied_scn Oracle SCN of the newest applied batch - the Adabas-side watermark."
      emit "# TYPE sync_last_applied_scn gauge"
      emit "sync_last_applied_scn $scn"
    fi

    ts=$(stat -c %Y "$SYNC/applied/$last" 2>/dev/null)
    if [ -n "$ts" ]; then
      emit "# HELP sync_last_applied_timestamp_seconds When the newest batch was acknowledged."
      emit "# TYPE sync_last_applied_timestamp_seconds gauge"
      emit "sync_last_applied_timestamp_seconds $ts"
    fi
  fi

  # --- what failed, and why -------------------------------------------------
  #
  # The cheap half of "no payload inspector this round": the reason a batch was
  # refused travels WITH the batch - run-apply.sh copies the applier's result file
  # into the directory before it is acknowledged - so a rejected batch carries its
  # own explanation and Grafana can table it without Loki.
  if [ "$rejected" -gt 0 ]; then
    emit "# HELP sync_batch_rejected One series per rejected batch, labelled with the reason the applier gave."
    emit "# TYPE sync_batch_rejected gauge"
    for d in "$SYNC/rejected"/batch-*; do
      [ -d "$d" ] || continue
      b=$(basename "$d")
      reason=$(grep -h 'REFUSED-\|REJECTED-' "$d"/apply_result*.txt 2>/dev/null | head -1)
      [ -n "$reason" ] || reason="apply failed - see $b/apply_result.txt"
      emit "sync_batch_rejected{batch=\"$b\",reason=\"$(sanitize "$reason")\"} 1"
    done
  fi

  emit "# HELP sync_exporter_build_duration_seconds How long this rebuild took."
  emit "# TYPE sync_exporter_build_duration_seconds gauge"
  emit "sync_exporter_build_duration_seconds $(($(date +%s) - now))"

  mv "$TMP" "$OUTFILE"
}

mkdir -p "$(dirname "$OUTFILE")"
build
echo "sync-metrics: serving $OUTFILE, rebuilding every ${INTERVAL}s"
while :; do
  sleep "$INTERVAL"
  build 2>/dev/null || echo "sync-metrics: rebuild failed, keeping the previous file"
done
