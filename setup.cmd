@echo off
rem Double-click installer. Same as: powershell -ExecutionPolicy Bypass -File setup.ps1
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
echo.
pause
