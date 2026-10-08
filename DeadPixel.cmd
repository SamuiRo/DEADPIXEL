@echo off
:: Runs DEADPIXEL elevated. Args are passed through, e.g.: DeadPixel.cmd -Days 60
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DeadPixel.ps1" %*
pause
