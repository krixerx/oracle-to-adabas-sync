@echo off
rem Launch the Apache Hop GUI for the Oracle to Adabas sync project.
rem Set HOP_HOME to wherever the Hop desktop client is installed, or edit the
rem default below.
rem
rem ORACLE_HOST=localhost overrides the project default ("oracle" = Docker-internal
rem hostname) so the GUI on the host can reach Oracle on localhost:1521.
rem NOTE: this set alone is NOT enough - Hop project variables override OS
rem environment variables. The 'local-gui' Hop environment (hop-env-local-gui.json)
rem is the layer that actually wins; select it once in the GUI.
if "%HOP_HOME%"=="" set HOP_HOME=C:\hop
set ORACLE_HOST=localhost
cd /d "%HOP_HOME%"
start "Apache Hop GUI" hop-gui.bat
