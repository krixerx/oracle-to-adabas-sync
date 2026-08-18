#!/bin/sh
# One tiny container does two jobs: it serves the metrics file Prometheus
# scrapes, and it receives Alertmanager's webhook so an alert survives with
# nobody watching.
#
#   GET  /sync.prom       the metrics, rebuilt every BUILD_INTERVAL seconds
#   POST /cgi-bin/alert   Alertmanager notifications, appended to /alerts
#
# The image is `python:3-alpine`, pulled and not built: the shell script needs
# busybox (find, awk, sed, stat) and the server needs a working HTTP stack.
# Alpine alone would have been enough except that Alpine moved the busybox httpd
# applet out of the base package, and installing it would need the network on
# every container start - which this lab does not have by requirement.
set -eu

export TEXTFILE="${TEXTFILE:-/www/sync.prom}"
mkdir -p "$(dirname "$TEXTFILE")" /alerts

# The server first: it answers 503 until the first rebuild lands, which is a
# clearer thing for Prometheus to see than a connection refused.
python3 /opt/sync-exporter/serve.py &

exec sh /opt/sync-exporter/sync-metrics.sh
