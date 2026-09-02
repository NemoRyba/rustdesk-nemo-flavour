@echo off
REM ============================================================================
REM  Double-click to fast-rebuild the TBFDesk (RustDesk-Nemo) Windows client.
REM  Wraps build-run-windows-client.ps1 -Fast (lto=off, incremental, ~20s-2min).
REM  It stops any running client first (so the new build can be staged), builds,
REM  stages to run-windows-client\, and launches it.
REM ============================================================================
cd /d "%~dp0"
title Build TBFDesk client (fast)

echo Stopping any running client so the new build can be staged...
taskkill /IM rustdesk.exe /F >nul 2>&1
timeout /t 2 /nobreak >nul

echo Building (fast profile)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-run-windows-client.ps1" -Fast
set EXITCODE=%ERRORLEVEL%

echo.
if "%EXITCODE%"=="0" (
  echo Build finished OK. The client was staged and launched.
) else (
  echo Build FAILED with exit code %EXITCODE% - see the messages above.
)
echo.
echo Press any key to close this window.
pause >nul
