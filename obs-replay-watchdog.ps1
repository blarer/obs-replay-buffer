# OBS replay buffer watchdog. Runs from Task Scheduler via obs-watchdog-gate.vbs,
# which only starts this script when there may be something to do.
# - First run each boot: launch OBS silently with the replay buffer, in the tray.
# - OBS closed later:   toast with Relaunch / Stay-off buttons. No answer in
#                       5 min -> relaunch anyway.
# Keeping the replay buffer running while OBS is open is done inside OBS by
# obs-replay-flush.lua, so this script never talks to OBS (no websocket).
# Logic lives in obs-watchdog-common.ps1. Actions are logged to obs-watchdog.log.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'obs-watchdog-common.ps1')

try {
    Invoke-Watchdog
} catch {
    Write-Log 'watchdog' "ERROR: $($_.Exception.Message)"
    exit 1
}
