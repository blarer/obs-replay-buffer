# OBS replay buffer watchdog
# - First run each boot: launch OBS silently with replay buffer, minimized to tray
# - OBS closed later:   toast with Relaunch / Stay-off buttons; no answer in 5 min -> relaunch anyway
# - OBS running:        ensure replay buffer active via obs-websocket
$ErrorActionPreference = 'Stop'

$obsExe    = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe'
$obsDir    = 'C:\Program Files\obs-studio\bin\64bit'
$wsPort    = 4455
$wsConfig  = "$env:APPDATA\obs-studio\plugin_config\obs-websocket\config.json"
$stateFile = "$PSScriptRoot\obs-watchdog-state.json"
$graceMinutes = 5
$toastAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

function Launch-Obs {
    Start-Process -FilePath $obsExe -WorkingDirectory $obsDir `
        -ArgumentList '--startreplaybuffer', '--minimize-to-tray', '--disable-shutdown-check'
}

function Show-Toast {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
    $xml = @"
<toast scenario="reminder" activationType="protocol" launch="obs-watchdog:relaunch">
  <visual>
    <binding template="ToastGeneric">
      <text>OBS closed - replay buffer is OFF</text>
      <text>Auto-restarts in $graceMinutes minutes unless you pick.</text>
    </binding>
  </visual>
  <actions>
    <action content="Relaunch now" activationType="protocol" arguments="obs-watchdog:relaunch"/>
    <action content="Stay off 5 min" activationType="protocol" arguments="obs-watchdog:snooze"/>
  </actions>
  <audio src="ms-winsoundevent:Notification.Default"/>
</toast>
"@
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification($doc)
    $toast.Tag = 'obs-watchdog'
    $toast.Group = 'obs-watchdog'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($toastAppId).Show($toast)
}

function Remove-Toast {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotificationManager]::History.Remove('obs-watchdog', 'obs-watchdog', $toastAppId)
    } catch {}
}

$state = @{ lastSeenBoot = ''; snoozeUntil = ''; graceUntil = '' }
if (Test-Path $stateFile) {
    try {
        $j = Get-Content $stateFile -Raw | ConvertFrom-Json
        $state.lastSeenBoot = [string]$j.lastSeenBoot
        $state.snoozeUntil  = [string]$j.snoozeUntil
        $state.graceUntil   = [string]$j.graceUntil
    } catch {}
}
function Save-State { $state | ConvertTo-Json | Set-Content $stateFile }

$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')

if (-not (Get-Process obs64 -ErrorAction SilentlyContinue)) {

    if ($state.lastSeenBoot -ne $boot) {
        # first launch this boot - silent, no questions
        Launch-Obs
        $state.lastSeenBoot = $boot
        $state.snoozeUntil  = ''
        $state.graceUntil   = ''
        Save-State
        exit 0
    }

    if ($state.snoozeUntil -and (Get-Date) -lt [datetime]$state.snoozeUntil) {
        exit 0   # user chose Stay off - respect it
    }

    if ($state.graceUntil) {
        if ((Get-Date) -lt [datetime]$state.graceUntil) {
            exit 0   # toast pending, still inside grace window
        }
        # grace expired with no answer - relaunch so recording is never forgotten
        Launch-Obs
        $state.graceUntil  = ''
        $state.snoozeUntil = ''
        Save-State
        Remove-Toast
        exit 0
    }

    # OBS newly closed - post toast and start grace timer
    Show-Toast
    $state.graceUntil = (Get-Date).AddMinutes($graceMinutes).ToString('o')
    Save-State
    exit 0
}

# OBS running - mark seen this boot, clear snooze/grace, drop stale toast
if ($state.lastSeenBoot -ne $boot -or $state.snoozeUntil -or $state.graceUntil) {
    if ($state.graceUntil) { Remove-Toast }
    $state.lastSeenBoot = $boot
    $state.snoozeUntil  = ''
    $state.graceUntil   = ''
    Save-State
}

# ensure replay buffer active over obs-websocket (v5 protocol)
$password = (Get-Content $wsConfig -Raw | ConvertFrom-Json).server_password

function Get-Sha256Base64([string]$s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))) }
    finally { $sha.Dispose() }
}

$cts = [System.Threading.CancellationTokenSource]::new(10000)
$ct  = $cts.Token
$ws  = [System.Net.WebSockets.ClientWebSocket]::new()

function Send-Json($obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 6 -Compress))
    $ws.SendAsync([ArraySegment[byte]]::new($bytes),
        [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
}

function Receive-Json {
    $buf = [byte[]]::new(65536)
    $seg = [ArraySegment[byte]]::new($buf)
    $ms  = [System.IO.MemoryStream]::new()
    do {
        $res = $ws.ReceiveAsync($seg, $ct).GetAwaiter().GetResult()
        $ms.Write($buf, 0, $res.Count)
    } while (-not $res.EndOfMessage)
    [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
}

try {
    $ws.ConnectAsync([Uri]"ws://127.0.0.1:$wsPort/", $ct).Wait()

    $hello    = Receive-Json   # op 0: Hello
    $identify = @{ op = 1; d = @{ rpcVersion = 1; eventSubscriptions = 0 } }
    if ($hello.d.authentication) {
        $secret = Get-Sha256Base64 ($password + $hello.d.authentication.salt)
        $identify.d.authentication = Get-Sha256Base64 ($secret + $hello.d.authentication.challenge)
    }
    Send-Json $identify
    $null = Receive-Json       # op 2: Identified

    Send-Json @{ op = 6; d = @{ requestType = 'GetReplayBufferStatus'; requestId = 'rb-status' } }
    $status = Receive-Json

    if (-not $status.d.responseData.outputActive) {
        Send-Json @{ op = 6; d = @{ requestType = 'StartReplayBuffer'; requestId = 'rb-start' } }
        $null = Receive-Json
    }

    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, '', $ct).Wait()
}
catch {
    # websocket unreachable (OBS still booting, server disabled) - retry next run
    exit 0
}
finally {
    $ws.Dispose()
    $cts.Dispose()
}
