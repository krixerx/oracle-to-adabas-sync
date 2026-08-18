@echo off
REM Shows one vehicle as ORACLE has it and as ADABAS has it, side by side.
REM
REM READ-ONLY - this does NOT synchronise anything. The sync is capture +
REM sync-pump.ps1; start both with sync-start.cmd. This only looks at the
REM result, and it reads Adabas through a separate Natural program (DUMPVEH)
REM so agreement here means the data really matches.
REM
REM A vehicle is a SET of Adabas records - file 12 holds one record per plate -
REM so the attributes are checked against every one of them, and each
REM registration is listed with its expiry (0 = still current).
REM
REM Usage:  check-vehicle.cmd CITZZ1JZW00000014
setlocal
cd /d "%~dp0"

if "%~1"=="" (
  echo usage: check-vehicle.cmd ^<base-vin^>   e.g. check-vehicle.cmd CITZZ1JZW00000014
  exit /b 2
)

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-vehicle.ps1 %1
endlocal
exit /b %errorlevel%
