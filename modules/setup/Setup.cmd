@echo off
:: Runs DEADPIXEL Setup elevated. No args = menu; otherwise args are passed through, e.g.: Setup.cmd -Recipe disk-power -Apply
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup.ps1" %*
if not "%~1"=="" pause
