# Handles toast button clicks via obs-watchdog: protocol
# URIs: obs-watchdog:relaunch | obs-watchdog:snooze
param([string]$Uri)
$ErrorActionPreference = 'SilentlyContinue'

$obsExe    = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe'
$obsDir    = 'C:\Program Files\obs-studio\bin\64bit'
$stateFile = "$PSScriptRoot\obs-watchdog-state.json"
$snoozeMinutes = 5

$state = @{ lastSeenBoot = ''; snoozeUntil = ''; graceUntil = '' }
if (Test-Path $stateFile) {
    $j = Get-Content $stateFile -Raw | ConvertFrom-Json
    $state.lastSeenBoot = [string]$j.lastSeenBoot
    $state.snoozeUntil  = [string]$j.snoozeUntil
    $state.graceUntil   = [string]$j.graceUntil
}

if ($Uri -match 'snooze') {
    $state.snoozeUntil = (Get-Date).AddMinutes($snoozeMinutes).ToString('o')
    $state.graceUntil  = ''
}
else {  # relaunch (default)
    $state.snoozeUntil = ''
    $state.graceUntil  = ''
    if (-not (Get-Process obs64 -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $obsExe -WorkingDirectory $obsDir `
            -ArgumentList '--startreplaybuffer', '--minimize-to-tray', '--disable-shutdown-check'
    }
}
$state | ConvertTo-Json | Set-Content $stateFile

# clear the toast from Action Center
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::History.Remove('obs-watchdog', 'obs-watchdog', $appId)
} catch {}
