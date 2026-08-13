@echo off
REM Starts the live Oracle -> Adabas synchronisation.
REM
REM Opens two extra windows and leaves them running:
REM   "O2A CAPTURE"  - reads the Oracle redo log, writes batch files
REM   "O2A PUMP"     - maps each batch with Hop and applies it to Adabas
REM
REM Close those windows (or Ctrl-C in them) to stop syncing.
REM Check a record afterwards with:  check-employee.cmd <personnel-id>
setlocal
cd /d "%~dp0"

echo === 1/3  lab containers ===
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\lab-up.ps1
if errorlevel 1 goto :fail

echo.
echo === 2/3  Hop Server (field mapping) ===
docker compose --profile sync up -d hop-server --wait
if errorlevel 1 goto :fail

echo.
echo === 3/3  starting capture + pump in their own windows ===

REM Capture runs for 8 hours, then exits on its own so a forgotten window
REM cannot mine the redo log indefinitely. Re-run this script to extend.
start "O2A CAPTURE" cmd /k ""%JAVA_HOME%\bin\java.exe" -jar capture\target\oracle-capture.jar capture\capture-local.properties 28800"

REM Give the connector time to mine the data dictionary before the pump
REM starts looking for batches - roughly 25 s from cold.
timeout /t 30 /nobreak >nul

start "O2A PUMP" cmd /k powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-pump.ps1 -Watch

echo.
echo ----------------------------------------------------------------
echo  SYNC IS RUNNING.
echo.
echo  Change something in Oracle:
echo    docker exec -it o2a-oracle sqlplus pocapp/pocapp@//localhost:1521/FREEPDB1
echo    UPDATE pocapp.employee SET city = 'MYTEST' WHERE personnel_id = '11100102';
echo    COMMIT;
echo.
echo  Then check Adabas (5-10 seconds later):
echo    check-employee.cmd 11100102
echo ----------------------------------------------------------------
endlocal
exit /b 0

:fail
echo.
echo FAILED to start the sync.
endlocal
exit /b 1
