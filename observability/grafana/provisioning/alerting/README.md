# Kept so Grafana does not log a provisioning error for a directory that is
# bind-mounted but empty. Nothing here on purpose: alert RULES live in
# Prometheus (observability/prometheus/alerts.yml), not in Grafana, so that
# they keep firing whether or not anyone is running a browser.
