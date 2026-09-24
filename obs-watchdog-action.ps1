# Handles toast button clicks via the obs-watchdog: protocol (HKCU).
# URIs: obs-watchdog:relaunch | obs-watchdog:snooze
param([string]$Uri)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'obs-watchdog-common.ps1')

try {
    Invoke-ToastAction $Uri
} catch {
    Write-Log 'button' "ERROR: $($_.Exception.Message)"
    exit 1
}
