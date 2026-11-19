@echo off
rem Double-click uninstaller. Same as: powershell -ExecutionPolicy Bypass -File setup.ps1 -Uninstall
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" -Uninstall
echo.
pause
