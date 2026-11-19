@echo off
rem Runs every test suite. Lua suites need `lua` (5.x) and `luajit` on PATH
rem (scoop install lua luajit); they are skipped if missing. PowerShell suites
rem always run. tests\test-gate.ps1 needs OBS to be running.
setlocal
cd /d "%~dp0"
set FAILED=0

echo === tests\test-setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-setup.ps1 || set FAILED=1
echo === tests\test-watchdog.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-watchdog.ps1 || set FAILED=1
echo === tests\test-gate.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-gate.ps1 || set FAILED=1

where lua >nul 2>&1 && (
  echo === tests\test-obs-sort.lua
  lua tests\test-obs-sort.lua || set FAILED=1
  echo === tests\test-obs-keepalive.lua
  lua tests\test-obs-keepalive.lua || set FAILED=1
) || echo SKIP lua suites: lua not on PATH

where luajit >nul 2>&1 && (
  echo === tests\test-obs-win32.lua
  luajit tests\test-obs-win32.lua || set FAILED=1
  echo === tests\test-obs-collision.lua
  luajit tests\test-obs-collision.lua || set FAILED=1
) || echo SKIP luajit suites: luajit not on PATH

echo.
if %FAILED%==1 (echo SOME TESTS FAILED & exit /b 1) else (echo ALL TESTS PASSED & exit /b 0)
