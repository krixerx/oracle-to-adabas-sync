#!/usr/bin/env python3
"""Two endpoints, no framework, no dependencies beyond the standard library.

    GET  /sync.prom       the metrics file sync-metrics.sh rebuilds on a timer
    POST /cgi-bin/alert   Alertmanager's webhook - appended to /alerts/alerts.log

WHY THIS EXISTS RATHER THAN busybox httpd. Alpine moved the httpd applet out of
the base busybox package, so `httpd` is simply absent - and installing it at
container start would need the network on every start, which this lab does not
have by requirement. Forty lines of stdlib is cheaper than a build step, and it
removes the CGI-permissions failure mode entirely (busybox httpd answers 404,
not 403, when a CGI script is not executable, which is a miserable thing to
debug).

WHY THE ALERT SINK IS A FILE. Success criterion 1 of the observability design is
"killing the pump raises an alert within two minutes WITH NOBODY WATCHING". A
dashboard cannot satisfy that - someone has to be looking at it. Alertmanager
can, but every receiver it ships (email, Slack, PagerDuty) needs the internet.
A webhook to a local file is the one notification channel that works air-gapped,
and it is the same shape a real deployment uses to hand alerts to whatever the
customer already operates.
"""
import json
import os
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

METRICS = os.environ.get("TEXTFILE", "/www/sync.prom")
ALERT_DIR = os.environ.get("ALERT_DIR", "/alerts")
PORT = int(os.environ.get("HTTP_PORT", "9101"))


class Handler(BaseHTTPRequestHandler):
    # The default logs one line per scrape - every 15 seconds, forever. Silence
    # them so `docker logs` stays useful for the things that actually matter.
    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, content_type="text/plain; charset=utf-8"):
        payload = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/sync.prom", "/metrics"):
            try:
                with open(METRICS, "r", encoding="utf-8") as fh:
                    self._send(200, fh.read())
            except FileNotFoundError:
                # Before the first rebuild. 503 rather than an empty 200: an
                # empty scrape would look like "every counter is zero", which is
                # a different and much more alarming statement than "not ready".
                self._send(503, "metrics not built yet\n")
            return
        if path == "/healthz":
            self._send(200, "ok\n")
            return
        self._send(404, "not found\n")

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/cgi-bin/alert":
            self._send(404, "not found\n")
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8", "replace")
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        try:
            payload = json.loads(raw)
            status = payload.get("status", "?")
            for alert in payload.get("alerts", [{}]):
                labels = alert.get("labels", {})
                annotations = alert.get("annotations", {})
                line = "{}  {:<8}  {:<24}  {}".format(
                    stamp,
                    alert.get("status", status).upper(),
                    labels.get("alertname", "?"),
                    annotations.get("summary", ""),
                )
                _append("alerts.log", line)
        except (ValueError, AttributeError):
            _append("alerts.log", "{}  RAW       {}".format(stamp, raw[:500]))

        # The full payload, kept separately: the human-readable line drops
        # detail on purpose, and an alert nobody can reconstruct afterwards is
        # half an alert.
        _append("alerts.jsonl", raw)
        self._send(200, "logged\n")


def _append(name, line):
    os.makedirs(ALERT_DIR, exist_ok=True)
    with open(os.path.join(ALERT_DIR, name), "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


if __name__ == "__main__":
    print("alert sink + metrics on :{}".format(PORT), flush=True)
    try:
        ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
