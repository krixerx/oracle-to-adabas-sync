@echo off
REM Shows one traffic fine as ORACLE has it and as ADABAS has it, side by side.
REM
REM This is how you verify a sync actually landed: the Adabas side is read
REM by a separate Natural program (DUMPFIN), never by the sync's own
REM bookkeeping - so agreement here means the data really matches.
REM
REM Usage:  check-fine.cmd F000000005
setlocal
cd /d "%~dp0"

if "%~1"=="" (
  echo usage: check-fine.cmd ^<fine-no^>     e.g. check-fine.cmd F000000005
  exit /b 2
)

powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check-fine.ps1 %1
endlocal
exit /b %errorlevel%
