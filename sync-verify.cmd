@echo off
REM Acceptance suite: runs the success criteria from the spec and prints
REM "SYNC VERIFIED: n/n". Companion to the sibling repo's migrate.cmd.
REM
REM Criterion 10 (conflict detection) is SKIPPED by design - it is a documented
REM out-of-scope item, not a broken run - so a healthy run reports 11/12 and
REM exits 0.
REM
REM One-time prerequisites, in this order, before the first run ever:
REM     scripts\lab-up.ps1              (brings the containers up)
REM     scripts\setup-cdc.ps1           (Oracle ARCHIVELOG + supplemental logging + users)
REM     scripts\setup-adabas-ledger.ps1 (Adabas file 99, the apply watermark)
REM     mvn -f capture\pom.xml package  (builds the capture jar)
setlocal
cd /d "%~dp0"

rem --- preflight: the Oracle JDBC driver is NOT in this repo -----------------
rem docker-compose bind-mounts hop\lib\ojdbc11.jar as a FILE. If it is missing,
rem Docker silently creates a DIRECTORY with that name, Hop Server starts with
rem no JDBC driver and fails obscurely - and the junk directory then has to be
rem deleted before the real jar will mount. Fail clearly here instead.
if not exist "hop\lib\ojdbc11.jar" (
  echo.
  echo ERROR: hop\lib\ojdbc11.jar is missing.
  echo.
  echo   The Oracle JDBC driver is not redistributed in this repository
  echo   ^(Oracle OTN licence^). Download ojdbc11.jar and place it at:
  echo       hop\lib\ojdbc11.jar
  echo.
  echo   https://www.oracle.com/database/technologies/appdev/jdbc-downloads.html
  echo.
  exit /b 2
)
dir /a-d "hop\lib\ojdbc11.jar" >nul 2>&1
if errorlevel 1 (
  echo.
  echo ERROR: hop\lib\ojdbc11.jar exists but is a DIRECTORY, not a file.
  echo   Docker created it on an earlier run. Delete it, then put the real
  echo   ojdbc11.jar there:  rmdir /s /q "hop\lib\ojdbc11.jar"
  echo.
  exit /b 2
)

rem --- preflight: the capture jar must be built ------------------------------
if not exist "capture\target\oracle-capture.jar" (
  echo.
  echo ERROR: capture\target\oracle-capture.jar is missing.
  echo   Build it first:  mvn -f capture\pom.xml package
  echo.
  exit /b 2
)

echo [1/3] Bringing the lab up ...
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\lab-up.ps1
if errorlevel 1 goto :fail

echo.
echo [2/3] Starting Hop Server (sync profile) ...
docker compose --profile sync up -d hop-server --wait
if errorlevel 1 goto :fail

echo.
echo [3/3] Running the verification suite ...
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-verify.ps1
if errorlevel 1 goto :fail

endlocal
exit /b 0

:fail
echo.
echo SYNC VERIFICATION FAILED.
endlocal
exit /b 1
