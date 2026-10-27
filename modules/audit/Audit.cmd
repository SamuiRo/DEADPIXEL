@echo off
:: Runs DEADPIXEL Audit elevated (all checks). Args are passed through, e.g.: Audit.cmd -Area platform
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0' -ArgumentList '%*'"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Audit.ps1" -Save %*
pause
