@echo off
REM Starts the monitoring stack: exporter, Prometheus, Alertmanager, Grafana.
REM
REM It is an OBSERVER, never a dependency. The sync runs correctly with all of
REM this stopped, and nothing here can touch the queue - /sync is mounted
REM read-only into the only container that reads it.
REM
REM   sync-monitor.cmd          start it
REM   sync-monitor.cmd stop     stop it (the sync keeps running)
setlocal
cd /d "%~dp0"

if /i "%~1"=="stop" goto :stop

REM The four services are named explicitly on purpose. A bare
REM `--profile observability up` would ALSO start every profile-less service -
REM adabas, natural, oracle - because compose always starts those. Monitoring
REM must not drag the lab up behind it.
echo === starting the observability stack ===
docker compose --profile observability up -d sync-exporter prometheus alertmanager grafana
if errorlevel 1 goto :fail

echo.
echo ----------------------------------------------------------------
echo  Grafana        http://localhost:3000/d/o2a-sync   (anonymous, or admin/admin)
echo  Prometheus     http://localhost:9090/alerts
echo  Alertmanager   http://localhost:9093
echo  Raw metrics    http://localhost:9101/sync.prom
echo.
echo  Alerts are appended to sync\alerts\alerts.log - that file is what
echo  fires when nobody is watching the dashboard.
echo.
echo  NOTE: the pump only writes a heartbeat in -Watch mode, so the
echo  "Pump" panel reads "never started" until sync-start.cmd has run.
echo ----------------------------------------------------------------
endlocal
exit /b 0

:stop
REM Same reasoning: remove only these four, never `down`, which would take the
REM databases with it.
docker compose --profile observability rm -sf sync-exporter prometheus alertmanager grafana
endlocal
exit /b 0

:fail
echo.
echo FAILED to start the observability stack.
endlocal
exit /b 1
