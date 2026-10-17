# Shared code for the OBS replay-buffer watchdog.
# Dot-sourced by obs-replay-watchdog.ps1, obs-watchdog-action.ps1 and
# test-watchdog.ps1. Keep this file plain ASCII: Windows PowerShell 5.1
# misreads UTF-8 files that have no BOM.
#
# State file fields (obs-watchdog-state.json):
#   lastSeenBoot  raw WMI LastBootUpTime of the boot we last handled. The
#                 raw string (e.g. 20260924085141.500000-240) is used so the
#                 VBS gate can compare it without date parsing.
#   graceUntil    set when the "OBS closed" toast is shown. When it passes
#                 with no answer, OBS is relaunched.
#   snoozeUntil   set by the "Stay off 5 min" button.
#   restarts      OBS restarts done this boot because obs-replay-flush.lua
#                 asked for one (replay buffer kept failing to start).
#
# obs-restart-request (file, written by obs-replay-flush.lua) means: OBS is
# running but its replay buffer can't start, please restart OBS. Seen
# 2026-10-17: NVENC failed to load at launch, so the encoder didn't exist.

$WatchdogDir = if ($env:OBS_WATCHDOG_STATEDIR) { $env:OBS_WATCHDOG_STATEDIR } else { $PSScriptRoot }
$StateFile   = Join-Path $WatchdogDir 'obs-watchdog-state.json'
$LogFile     = Join-Path $WatchdogDir 'obs-watchdog.log'
$RequestFile = Join-Path $WatchdogDir 'obs-restart-request'

$ObsExe        = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe'
$ObsDir        = Split-Path $ObsExe
$NvencTest     = Join-Path $ObsDir 'obs-nvenc-test.exe'
$GraceMinutes  = 5
$SnoozeMinutes = 5
$MaxRestarts   = 2       # per boot, so a broken setup can't restart-loop
$NvencWaitSec  = 60      # max wait for NVENC before launching anyway. Keep
                         # waits + test timeouts + Stop-Obs under the task's
                         # 3 min ExecutionTimeLimit (worst case ~150 s).
$LogMaxBytes   = 256KB
# Toasts need an AppID Windows already knows. This is PowerShell's own.
$ToastAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

# ------------------------------------------------------------ environment ---
# Small wrappers so tests can replace them.

function Get-Now { Get-Date }

function Get-BootId { [string](Get-WmiObject Win32_OperatingSystem).LastBootUpTime }

function Test-ObsRunning { [bool](Get-Process obs64 -ErrorAction SilentlyContinue) }

# The Lua deletes the request within ~1 s if the start it made right after
# writing it succeeded, so only trust a request that has stood for 5 s.
function Test-RestartRequested {
    $f = Get-Item $RequestFile -ErrorAction SilentlyContinue
    [bool]($f -and ((Get-Now) - $f.LastWriteTime).TotalSeconds -ge 5)
}

function Clear-RestartRequest { Remove-Item $RequestFile -Force -ErrorAction SilentlyContinue }

function Wait-Seconds([int]$n) { Start-Sleep -Seconds $n }

# OBS checks NVENC once, at startup, by running obs-nvenc-test.exe. If that
# fails (driver still settling after boot) NVENC stays off until OBS restarts,
# and the AV1 replay buffer can never start. Run the same test first.
function Test-NvencReady {
    if (-not (Test-Path $NvencTest)) { return $true }   # can't check: don't block
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo $NvencTest
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $p = [Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch {}; return $false }
        return [bool]($out.Result -match 'nvenc_supported=true')
    } catch { return $true }
}

# Returns seconds waited, or -1 if NVENC never became ready.
function Wait-NvencReady {
    $waited = 0
    while (-not (Test-NvencReady)) {
        if ($waited -ge $NvencWaitSec) { return -1 }
        Wait-Seconds 5; $waited += 5
    }
    $waited
}

# Polite close first (lets OBS save and remove its crash marker), then force.
function Stop-Obs {
    $p = @(Get-Process obs64 -ErrorAction SilentlyContinue)
    if (-not $p) { return }
    & taskkill.exe /im obs64.exe *> $null
    try { $p | Wait-Process -Timeout 15 -ErrorAction Stop }
    catch { Get-Process obs64 -ErrorAction SilentlyContinue | Stop-Process -Force }
    Start-Sleep -Seconds 2
}

# OBS 32 marks a running instance with a file in .sentinel and deletes it on a
# clean exit. A leftover file (crash, force-kill, power loss, forced update
# restart) makes the next start stop at a modal "Crash Detected / Run in Safe
# Mode?" dialog, BEFORE anything loads: no replay buffer, no Lua. The old
# --disable-shutdown-check flag that skipped this was removed in OBS 32. So
# clear stale markers before each launch. Only called when no OBS is running,
# so a live instance's marker is never touched. The crash log itself stays in
# obs-studio\crashes.
$SentinelDir = if ($env:OBS_WATCHDOG_SENTINELDIR) { $env:OBS_WATCHDOG_SENTINELDIR } `
               else { Join-Path $env:APPDATA 'obs-studio\.sentinel' }

function Clear-ObsCrashFlag {
    if (-not (Test-Path $SentinelDir)) { return 0 }
    $stale = @(Get-ChildItem $SentinelDir -File -Filter 'run_*' -ErrorAction SilentlyContinue)
    foreach ($f in $stale) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue }
    $stale.Count
}

function Start-Obs {
    if (Test-ObsRunning) { return }   # never start a second instance
    Clear-RestartRequest              # belongs to the OBS that is gone
    $w = Wait-NvencReady
    if ($w -lt 0) { Write-Log 'launch' "NVENC still not ready after $NvencWaitSec s: launching anyway" }
    elseif ($w -gt 0) { Write-Log 'launch' "waited $w s for NVENC to be ready" }
    $n = Clear-ObsCrashFlag
    if ($n) { Write-Log 'launch' "OBS last exited uncleanly: cleared $n crash marker(s) so it starts without the Safe Mode prompt" }
    Start-Process -FilePath $ObsExe -WorkingDirectory $ObsDir `
        -ArgumentList '--startreplaybuffer', '--minimize-to-tray'
}

function Show-Toast {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
    $xml = @"
<toast scenario="reminder" activationType="protocol" launch="obs-watchdog:relaunch">
  <visual>
    <binding template="ToastGeneric">
      <text>OBS closed - replay buffer is OFF</text>
      <text>Auto-restarts in $GraceMinutes minutes unless you pick.</text>
    </binding>
  </visual>
  <actions>
    <action content="Relaunch now" activationType="protocol" arguments="obs-watchdog:relaunch"/>
    <action content="Stay off $SnoozeMinutes min" activationType="protocol" arguments="obs-watchdog:snooze"/>
  </actions>
  <audio src="ms-winsoundevent:Notification.Default"/>
</toast>
"@
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = New-Object Windows.UI.Notifications.ToastNotification($doc)
    $toast.Tag = 'obs-watchdog'
    $toast.Group = 'obs-watchdog'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show($toast)
}

function Remove-Toast {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotificationManager]::History.Remove('obs-watchdog', 'obs-watchdog', $ToastAppId)
    } catch {}
}

# Plain notice, no buttons. Used when automatic recovery has given up.
function Show-Notice([string]$Title, [string]$Body) {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml("<toast><visual><binding template='ToastGeneric'><text></text><text></text></binding></visual></toast>")
    $t = $doc.GetElementsByTagName('text')
    $null = $t.Item(0).AppendChild($doc.CreateTextNode($Title))
    $null = $t.Item(1).AppendChild($doc.CreateTextNode($Body))
    $toast = New-Object Windows.UI.Notifications.ToastNotification($doc)
    $toast.Tag = 'obs-notice'; $toast.Group = 'obs-watchdog'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ToastAppId).Show($toast)
}

# ---------------------------------------------------------------- logging ---
# One line per real action. Quiet runs write nothing. Rotates at 256 KB.

function Write-Log([string]$Source, [string]$Message) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt $LogMaxBytes) {
            Move-Item $LogFile "$LogFile.1" -Force
        }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Source, $Message
        [IO.File]::AppendAllText($LogFile, $line + "`r`n")
    } catch {}
}

# ------------------------------------------------------------------ state ---

function New-State { [ordered]@{ lastSeenBoot = ''; snoozeUntil = ''; graceUntil = ''; restarts = '' } }

function Read-State {
    $s = New-State
    if (Test-Path $StateFile) {
        try {
            $j = [IO.File]::ReadAllText($StateFile) | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($null -ne $j.$k) { $s[$k] = [string]$j.$k } }
        } catch {
            Write-Log 'state' "state file unreadable, starting fresh: $($_.Exception.Message)"
        }
    }
    $s
}

# Write to a temp file, then swap it in, so a reader (or a crash) never sees
# a half-written file. Retries briefly in case the VBS gate is reading it.
function Save-State($s) {
    $tmp  = "$StateFile.tmp"
    $json = $s | ConvertTo-Json
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    for ($i = 1; ; $i++) {
        try {
            # [NullString]: PowerShell turns a plain $null into "" for string
            # parameters, which Replace rejects as "not of a legal form".
            if (Test-Path $StateFile) { [IO.File]::Replace($tmp, $StateFile, [NullString]::Value, $true) }
            else { [IO.File]::Move($tmp, $StateFile) }
            return
        } catch {
            if ($i -ge 10) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
}

function ConvertTo-Time([string]$s) {
    if (-not $s) { return $null }
    $t = [datetime]::MinValue
    $ok = [datetime]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)
    if ($ok) { $t } else { $null }
}

# Both scripts read-modify-write the state file and may launch OBS. The lock
# stops a button click and a watchdog run from racing each other.
function Invoke-Locked([scriptblock]$Body) {
    $m = New-Object Threading.Mutex($false, 'Local\obs-watchdog')
    $held = $false
    try {
        try { $held = $m.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { Write-Log 'lock' 'timed out waiting for lock, skipped this run'; return }
        & $Body
    } finally {
        if ($held) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

# --------------------------------------------------------------- decision ---
# Before 2026-09-24 lastSeenBoot was stored as ISO time
# (2026-09-24T08:51:41.5000000-04:00). It is now the raw WMI string. If an old
# value names the SAME boot, rewrite it in the new format instead of treating
# it as a new boot (which would silently relaunch OBS instead of asking).
function Update-LegacyBoot($State, [string]$Boot) {
    $old = [string]$State.lastSeenBoot
    if ($old -notmatch 'T') { return $State }
    try {
        $then = ConvertTo-Time $old
        $now  = [Management.ManagementDateTimeConverter]::ToDateTime($Boot)
        if ($then -and [math]::Abs(($then.ToUniversalTime() - $now.ToUniversalTime()).TotalSeconds) -lt 2) {
            $State.lastSeenBoot = $Boot
        }
    } catch {}
    $State
}

# Pure: no side effects, so every branch is unit-tested.
# Returns @{ Action = ...; State = <new state> }.
#
#   OBS running:
#     restart requested by Lua         -> restart-obs, or restart-giveup
#                                          once $MaxRestarts were done this boot
#     state already current            -> none
#     otherwise (new boot / timers set) -> running-update, or
#                                          running-clear-toast if a toast was pending
#   OBS not running:
#     boot differs                     -> launch-boot   (silent, no question)
#     snoozed                          -> wait-snooze
#     toast pending, grace not over    -> wait-grace
#     toast pending, grace over        -> relaunch-grace
#     otherwise (just closed)          -> toast
function Get-WatchdogDecision {
    param($State, [string]$Boot, [bool]$ObsRunning, [datetime]$Now, [bool]$RestartRequested = $false)

    $s = New-State
    foreach ($k in @($s.Keys)) { $s[$k] = [string]$State[$k] }
    if ($s.lastSeenBoot -ne $Boot) { $s.restarts = '' }   # the cap is per boot

    if ($ObsRunning) {
        if ($RestartRequested) {
            $n = 0; $null = [int]::TryParse($s.restarts, [ref]$n)
            $s.lastSeenBoot = $Boot; $s.snoozeUntil = ''; $s.graceUntil = ''
            if ($n -ge $MaxRestarts) { return @{ Action = 'restart-giveup'; State = $s } }
            $s.restarts = [string]($n + 1)
            return @{ Action = 'restart-obs'; State = $s }
        }
        if ($s.lastSeenBoot -eq $Boot -and -not $s.snoozeUntil -and -not $s.graceUntil) {
            return @{ Action = 'none'; State = $s }
        }
        $action = if ($s.graceUntil) { 'running-clear-toast' } else { 'running-update' }
        $s.lastSeenBoot = $Boot; $s.snoozeUntil = ''; $s.graceUntil = ''
        return @{ Action = $action; State = $s }
    }

    if ($s.lastSeenBoot -ne $Boot) {
        $s.lastSeenBoot = $Boot; $s.snoozeUntil = ''; $s.graceUntil = ''
        return @{ Action = 'launch-boot'; State = $s }
    }

    $snooze = ConvertTo-Time $s.snoozeUntil
    if ($snooze -and $Now -lt $snooze) { return @{ Action = 'wait-snooze'; State = $s } }

    $grace = ConvertTo-Time $s.graceUntil
    if ($grace) {
        if ($Now -lt $grace) { return @{ Action = 'wait-grace'; State = $s } }
        $s.snoozeUntil = ''; $s.graceUntil = ''
        return @{ Action = 'relaunch-grace'; State = $s }
    }

    # Just closed (or an unreadable timer, which self-heals here).
    $s.snoozeUntil = ''
    $s.graceUntil = $Now.AddMinutes($GraceMinutes).ToString('o')
    return @{ Action = 'toast'; State = $s }
}

# ---------------------------------------------------------------- runners ---

function Invoke-Watchdog {
    Invoke-Locked {
        $boot  = Get-BootId
        $raw   = Read-State
        $before = $raw.lastSeenBoot
        $state = Update-LegacyBoot $raw $boot
        $d = Get-WatchdogDecision -State $state -Boot $boot `
                -ObsRunning (Test-ObsRunning) -Now (Get-Now) `
                -RestartRequested (Test-RestartRequested)
        if ($d.Action -in 'none', 'wait-snooze', 'wait-grace') {
            # A migrated legacy boot must still be written, or the VBS gate
            # never sees a match and starts PowerShell every minute.
            if ($d.State.lastSeenBoot -ne $before) {
                Save-State $d.State
                Write-Log 'watchdog' 'migrated lastSeenBoot to the new format'
            }
            return
        }

        # Persist BEFORE any side effect: if the toast or launch fails, the
        # timers are already saved and the next run still does the right thing.
        Save-State $d.State

        switch ($d.Action) {
            'launch-boot' {
                Start-Obs
                Write-Log 'watchdog' 'first run this boot: launched OBS'
            }
            'toast' {
                try {
                    Show-Toast
                    Write-Log 'watchdog' "OBS closed: toast shown, auto-relaunch at $($d.State.graceUntil)"
                } catch {
                    Write-Log 'watchdog' "OBS closed: TOAST FAILED ($($_.Exception.Message)), auto-relaunch still at $($d.State.graceUntil)"
                }
            }
            'relaunch-grace' {
                Remove-Toast
                Start-Obs
                Write-Log 'watchdog' "no answer within $GraceMinutes min: relaunched OBS"
            }
            'running-clear-toast' {
                Remove-Toast
                Write-Log 'watchdog' 'OBS running again: cleared pending toast'
            }
            'running-update' { }   # routine bookkeeping, not worth a log line
            'restart-obs' {
                $why = Get-Content $RequestFile -TotalCount 1 -ErrorAction SilentlyContinue
                Stop-Obs
                Start-Obs   # also clears the request file
                Write-Log 'watchdog' "replay buffer could not start ($why): restarted OBS ($($d.State.restarts)/$MaxRestarts this boot)"
            }
            'restart-giveup' {
                Clear-RestartRequest
                Write-Log 'watchdog' "replay buffer still failing after $MaxRestarts OBS restarts this boot: gave up, notified user"
                try { Show-Notice 'OBS replay buffer is NOT running' 'Restarting OBS did not fix it. Open OBS to see the error. Clips are not being saved.' }
                catch { Write-Log 'watchdog' "NOTICE FAILED ($($_.Exception.Message))" }
            }
        }
    }
}

function Invoke-ToastAction([string]$Uri) {
    Invoke-Locked {
        $s = Read-State
        if ($Uri -match 'snooze') {
            $s.snoozeUntil = (Get-Now).AddMinutes($SnoozeMinutes).ToString('o')
            $s.graceUntil  = ''
            Save-State $s
            Write-Log 'button' "Stay off: snoozed until $($s.snoozeUntil)"
        } else {
            $s.snoozeUntil = ''
            $s.graceUntil  = ''
            Save-State $s
            if (Test-ObsRunning) {
                Write-Log 'button' 'Relaunch now: OBS was already running'
            } else {
                Start-Obs
                Write-Log 'button' 'Relaunch now: launched OBS'
            }
        }
    }
    Remove-Toast
}
