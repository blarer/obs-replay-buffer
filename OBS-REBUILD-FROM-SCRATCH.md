# Rebuild Guide: Always-On OBS Replay Buffer, Close Notification, Clip Sorting

Written 2026-09-24 for an AI (or human) with **no memory** of the original work. Follow it top to bottom on a fresh Windows 11 PC and you get the exact same setup. Every value here was read off the working machine, not guessed. The full source of every script is in the **Appendix** at the bottom, so this file alone is enough even if `C:\Users\blare\Scripts` is gone.

---

## 0. What the finished system does

1. You log in. About 30 seconds later OBS starts **silently in the system tray** with the **replay buffer already running**. No window, no prompt.
2. The replay buffer always holds the last 10 minutes of gameplay in RAM. Press **Alt+Z** to save it.
3. The saved clip is automatically moved into a per-game folder, e.g. `Videos\FortniteClient-Win64-Shipping\`. The folder is picked by which app **had focus for most of the clip**, not just whatever was on top when you pressed save.
4. After every save, the buffer is flushed so the next clip never repeats footage from the last one.
5. If you close OBS, a Windows notification pops up: **"OBS closed - replay buffer is OFF"** with two buttons:
   - **Relaunch now** starts OBS right away.
   - **Stay off 5 min** leaves it off for 5 minutes, then asks again.
   - **Ignore it**: after 5 minutes OBS restarts by itself. You can never *forget* to turn recording back on.
6. If OBS is running but the replay buffer got stopped somehow, it is silently turned back on within 1 minute.

## 1. How it fits together

```
Task Scheduler "OBS Replay Buffer Watchdog"   (at logon + every 1 minute)
   -> wscript run-hidden.vbs            (runs PowerShell with no window flash)
      -> obs-replay-watchdog.ps1
           OBS not running? -> first time this boot: launch silently
                            -> otherwise: toast + 5 min grace -> relaunch
           OBS running?     -> obs-websocket (port 4455): replay buffer on? if not, start it
                                   |
Toast buttons -> obs-watchdog:relaunch / obs-watchdog:snooze   (custom URL protocol)
   -> wscript run-hidden.vbs -> obs-watchdog-action.ps1  (updates state json)

obs-watchdog-state.json   shared memory between the two scripts

Inside OBS: obs-replay-flush.lua   (flush after save + sort clips into game folders)
```

Why these design choices:
- **Task Scheduler every minute**, not a background PowerShell loop. Nothing stays resident, and the task restarts itself after crashes, sleep, and reboots.
- **run-hidden.vbs**: launching `powershell.exe` from a task flashes a console window every minute, even with `-WindowStyle Hidden`. `wscript` with `Run cmd, 0` gives true zero-flash.
- **State file with the boot time**: this is how the script tells "PC just booted" (launch silently) apart from "user closed OBS" (ask first).
- **Protocol URLs for the toast buttons**: toasts shown from PowerShell cannot run code directly. A button can only open a URL. Registering `obs-watchdog:` as a URL scheme turns a click into a script call.
- **Grace-then-relaunch**: the core rule is *never lose a clip to an unanswered prompt*, while still letting the user turn OBS off on purpose.

---

## 2. Step by step build

User account on the original machine: `blare`. Replace it if different. Scripts live in `C:\Users\<user>\Scripts\`.

### Step 1. Install OBS

Install OBS Studio 32.x (the original runs 32.2.0) to the default path `C:\Program Files\obs-studio\`. Run it once normally so it creates `%APPDATA%\obs-studio\`. Do **not** set it to run as administrator (see section 3).

### Step 2. Create the OBS profile

OBS: Profile -> New -> name it `GameRec-AV1`. OBS will store it in `%APPDATA%\obs-studio\basic\profiles\GameRecAV1\` (the hyphen is dropped in the folder name. That is normal).

Settings -> Output -> Output Mode **Advanced**:

**Recording tab**
| Setting | Value |
|---|---|
| Type | Standard |
| Recording Path | `C:\Users\<user>\Videos` |
| Recording Format | **Hybrid MP4** (`hybrid_mp4`). Survives crashes like MKV but plays everywhere like MP4. |
| Audio Track | 1 and 2 (bitmask 3) |
| Video Encoder | **NVIDIA NVENC AV1** (`obs_nvenc_av1_tex`) |
| Rescale Output | off |
| Rate Control | **CQP**, CQ Level **20** |
| Keyframe Interval | 2 s |
| Preset | **P7** (slowest / best quality) |
| Tuning | High Quality |
| Multipass | Disabled |
| Profile | main |
| Look-ahead | off |
| Adaptive Quantization | on |
| B-frames | 2 |

**Audio tab**: Track 1 and Track 2 at **320 kbps** AAC (FFmpeg AAC).

**Replay Buffer tab**: enable it, Maximum Replay Time **600 s** (10 min), Maximum Memory **4096 MB**. Whichever limit hits first wins. Measured: a full Fortnite buffer is 600 s at ~3 GB (~42 Mbps), so the time limit is what binds and 4 GB is just headroom. Filename prefix `rb`.

Settings -> Output also: Filename formatting `%b %d %I.%M %p` gives names like `rb Sep 23 10.08 PM.mp4`.

Settings -> Video: Base and Output **2560x1440**, **60 FPS**, downscale filter Lanczos (unused since no scaling).
Settings -> Advanced: Color format NV12, color space 709, range Partial. Renderer Direct3D 11.
Settings -> Audio: 48 kHz, Stereo. Disable audio ducking (`DisableAudioDucking=true`).
Settings -> Hotkeys: **Replay Buffer -> Save Replay = Alt+Z**. Set "Hotkey focus behavior" to **Never disable hotkeys** so Alt+Z works while the game is focused.
Settings -> General: enable system tray. Leave "Show confirmation dialog on exit" as you like.

### Step 3. Sources (scene collection "Untitled")

One scene named `Scene` containing one source:
- **Game Capture** (`game_capture`), mode "Capture specific window", window `Fortnite :UnrealWindow:FortniteClient-Win64-Shipping.exe`. Game Capture hooks the game's own frames. Display Capture duplicates the whole desktop and costs more, so do not use it.

Audio: Desktop Audio + Desktop Audio 2 (both WASAPI output) and Mic/Aux + Mic/Aux 2 (WASAPI input) on the devices you use.

### Step 4. Enable obs-websocket

OBS -> Tools -> WebSocket Server Settings:
- Enable WebSocket server: **on**
- Port: **4455**
- Enable Authentication: **on**, generate a password.

The watchdog reads the password straight from `%APPDATA%\obs-studio\plugin_config\obs-websocket\config.json` (`server_password`). **Never copy the password into the script or any doc.**

### Step 5. Put the scripts in place

Create `C:\Users\<user>\Scripts\` and write these files exactly as in the Appendix:
- `run-hidden.vbs`
- `obs-replay-watchdog.ps1`
- `obs-watchdog-action.ps1`
- `obs-replay-flush.lua`
- optional tests: `test-obs-sort.lua`, `test-obs-win32.lua`, `test-obs-collision.lua`

`obs-watchdog-state.json` is created automatically. Do not create it by hand.

If the username or OBS path differs, fix the paths at the top of the two `.ps1` files.

### Step 6. Load the Lua script into OBS

OBS -> Tools -> Scripts -> `+` -> pick `obs-replay-flush.lua`. The Script Log should show:
```
replay-flush + smart game-sort loaded
```
After editing the script later, press the reload (circular arrows) button. No OBS restart needed.

### Step 7. Register the `obs-watchdog:` protocol (per user, no admin)

Register it under **HKCU**, not HKLM:

```powershell
$u = "C:\Users\$env:USERNAME\Scripts"
$k = 'HKCU:\Software\Classes\obs-watchdog'
New-Item "$k\shell\open\command" -Force | Out-Null
Set-ItemProperty $k '(default)' 'URL:OBS Watchdog Protocol'
Set-ItemProperty $k 'URL Protocol' ''
Set-ItemProperty "$k\shell\open\command" '(default)' "wscript.exe `"$u\run-hidden.vbs`" `"$u\obs-watchdog-action.ps1`" `"%1`""
```

### Step 8. Create the scheduled task

Must run as the **logged-in user with an interactive token**, **not** "highest privileges" and **not** SYSTEM. Otherwise the toast is invisible and OBS starts in the wrong session.

```powershell
$u   = "C:\Users\$env:USERNAME\Scripts"
$act = New-ScheduledTaskAction -Execute 'wscript.exe' `
         -Argument "`"$u\run-hidden.vbs`" `"$u\obs-replay-watchdog.ps1`""
$t1  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$t1.Delay = 'PT30S'
$t2  = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
         -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
         -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
$pr  = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask 'OBS Replay Buffer Watchdog' -Action $act -Trigger $t1,$t2 -Settings $set -Principal $pr
```

Alternatively import the exported definition: `schtasks /create /tn "OBS Replay Buffer Watchdog" /xml obs-watchdog-task.xml` (fix the user SID/name inside first on a new PC).

### Step 9. Verify (do all of these)

1. `Start-ScheduledTask 'OBS Replay Buffer Watchdog'` with OBS closed and a **fresh boot** -> OBS appears in the tray, replay buffer active, no prompt.
2. `Get-ScheduledTaskInfo 'OBS Replay Buffer Watchdog'` -> `LastTaskResult 0`.
3. Press Alt+Z in a game -> clip lands in `Videos\<GameExe>\`. OBS Script Log prints `sorted -> <folder>\<file>`.
4. Close OBS -> within 1 minute a toast appears. Click **Stay off 5 min** -> `obs-watchdog-state.json` shows `snoozeUntil` about 5 min ahead. (Confirmed working on the original machine 2026-09-24 10:32.)
5. Close OBS and ignore the toast -> about 5-6 minutes later OBS relaunches on its own.
6. Stop the replay buffer manually inside OBS -> within 1 minute it is running again.
7. `lua test-obs-sort.lua` -> `19 passed, 0 failed`. `luajit test-obs-win32.lua` -> `7 passed, 0 failed`. `luajit test-obs-collision.lua` -> `4 passed, 0 failed` (same-name saves get ` (2)`, ` (3)` instead of being stranded). (Install with `scoop install lua luajit`.)

---

## 3. Settings chosen for the cleanest resource use (and why)

Evidence from the original machine (OBS log, 2026-09-24, 1.5 hours of buffer while gaming): **32 of 334,977 frames skipped due to encoding lag (0.0%)**, **32 lagged due to rendering (0.0%)**, GPU encoder median 0.088 ms per frame. So this configuration is effectively free on this hardware (RTX 5090-class GPU, AMD X3D CPU, 2560x1440 at ~480 Hz OLED).

| Choice | Why it is the low-cost option |
|---|---|
| **NVENC (hardware) encoder** | Runs on the GPU's dedicated video engine, not CUDA cores or the CPU. x264 would eat CPU cores the game wants. |
| **AV1** | Smallest files at the same quality, so the 4 GB RAM buffer holds more minutes. Needs RTX 40-series or newer. On older cards use NVENC HEVC. |
| **CQP 20** | Constant quality, no bitrate juggling. Good for local clips (not for streaming). |
| **Preset P7** | Slowest NVENC preset, but it runs on the separate encoder block, so frame cost stayed 0.0% here. If you ever see "skipped frames due to encoding lag", drop to **P5** first. |
| **Look-ahead off, multipass disabled** | Both add GPU work and latency for little gain at CQP. |
| **No rescale (native 1440p)** | Scaling costs GPU render time. Encoding at native resolution avoids it. |
| **60 FPS** | Recording at the game's ~480 fps would multiply encoder work. 60 is plenty for clips. |
| **Game Capture, not Display Capture** | Hooks only the game's frames instead of duplicating the entire desktop. |
| **Replay buffer in RAM (4096 MB cap)** | No constant disk writes. Disk is only touched when you press save. |
| **Hybrid MP4** | Crash-safe without a remux step afterwards. |
| **OBS not run as admin** | Its log says `D3D11 GPU priority setup failed (not admin?)`. That is **intentional**. As admin, OBS raises its own GPU priority and can take frame time from the game. For a background clipper the game must win. |
| **Process priority Normal** | Same reason. Do not raise it. |
| **Lua sampler at 1 Hz, cached per window** | Costs ~0.008 microseconds per sample in steady state (measured). Note: OBS runs Lua timers on its video tick (render thread), so this is not "free by design", it is free because it is tiny: worst case ~33 us vs a 16,667 us frame. |
| **Watchdog every 1 min, then exits** | Nothing resident. Each run is a few ms of PowerShell, only if not already running (`IgnoreNew`). |

**Trade-off to know:** keeping the buffer running 24/7 keeps one NVENC session and ~4 GB of RAM busy all the time. A Sep 2026 Fortnite tuning pass listed it as the top thing to A/B test for 1% lows. The user chose to **keep it** because clipping matters more. To A/B test: `Disable-ScheduledTask 'OBS Replay Buffer Watchdog'`, close OBS, play, compare, then `Enable-ScheduledTask`.

---

## 4. History (what actually happened, in order)

1. **2026-07-03/04**: original build in a Claude Code session (transcript no longer exists). Created the profile, the watchdog, the action handler, the protocol, the task, `run-hidden.vbs`, and the first Lua flush script. That Lua version only checked the foreground window **once**, at save time.
2. **2026-08-05/06** (jcode session "fish"): clips were landing in the wrong folders, e.g. Discord when you alt-tabbed before saving. The Lua script was rewritten into the focus-over-time sampler: RLE spans, fullscreen weighting, desktop/overlay/content tiers, per-HWND caching, plus the two test files. Cost was benchmarked before and after.
3. **2026-09-13** (Claude Code session e629dab1): the profile was found **broken**: 720p30 and replay buffer off. It was rebuilt as the current `GameRec-AV1` (1440p60 NVENC AV1). Old profiles were backed up to `%LOCALAPPDATA%\Temp\claude\...\obs-profiles-backup-20260913-143837`. The fix was confirmed with a real save through the websocket. A test clip landed in `Videos\claude\`.
   - This left a **stale orphan folder** `profiles\GameRec-AV1\` (with a hyphen) holding an old encoder file. OBS does not use it. The live folder is `profiles\GameRecAV1\`. If you edit files by hand, edit the right one.
4. **2026-09-22** (jcode Fortnite optimization swarm): read-only audit. Found capture was Display Capture and recommended Game Capture. **The user switched it to Game Capture** (window mode, Fortnite).
5. **2026-09-24**: this guide. Live checks: task healthy, websocket settings match, script loaded, sorting working, toast + Stay off button confirmed working, both test suites pass.

---

## 5. Gotchas an AI must not get wrong

- **Never run the task as SYSTEM or with highest privileges.** The toasts vanish and OBS launches invisibly in another session.
- **Register the protocol under HKCU\Software\Classes**, not HKLM. No admin is needed.
- The toast AppID must be an app registered with Windows. The script borrows PowerShell's: `{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe`. A made-up AppID fails silently.
- **Stay off** snoozes for 5 minutes, then the toast **comes back** (it does not relaunch directly). **Ignoring** the toast relaunches after 5 minutes. These are two different paths, on purpose.
- `--disable-shutdown-check` stops OBS from showing the "OBS did not shut down properly, safe mode?" dialog after crashes or reboots. Without it the silent launch can hang on that dialog.
- obs-websocket v5 auth is `base64(sha256( base64(sha256(password + salt)) + challenge ))`.
- If a websocket call fails (OBS still starting), the script exits 0 and simply tries again next minute. That is expected, not an error.
- Clip folders are named after the **exe**, e.g. `FortniteClient-Win64-Shipping`, not a pretty game title.
- `.ps1` files must stay plain ASCII/UTF-8 without fancy dashes. PowerShell 5.1 misreads UTF-8 without BOM, and non-ASCII characters can break parsing.

---

## Appendix: full source of every file

### run-hidden.vbs

```vb
' Runs a PowerShell script with zero window flash.
' Usage: wscript.exe run-hidden.vbs <script.ps1> [args...]
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File"
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & " """ & WScript.Arguments(i) & """"
Next
sh.Run cmd, 0, False
```

### obs-replay-watchdog.ps1

```powershell
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
```

### obs-watchdog-action.ps1

```powershell
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
```

### obs-replay-flush.lua

```lua
-- OBS: replay-buffer flush + smart per-game clip sorting.
--
-- 1) Restarts the replay buffer after each save so consecutive clips never
--    contain overlapping footage.
-- 2) Sorts saved clips/recordings into per-game folders: Videos\<game>\clip....mp4
--
-- Folder choice is NOT a single snapshot of the foreground window. A 1 Hz
-- sampler records which app had focus over time, and on save we score only the
-- samples that fall inside the clip's own time window. The app with the most
-- weighted focus time wins, so:
--   * starting on the desktop then launching a game -> game folder
--   * alt-tabbing to Discord and then hitting save   -> still the game folder
--
-- The scoring half is pure and exported as OBS_CLIP_SORT for the test harness
-- (Scripts\test-obs-sort.lua), which runs under plain Lua with no OBS present.
--
-- Cost: obs timers run inside OBS's video tick (obs_add_tick_callback, the
-- render thread), so the sampler must stay tiny. It does, far under a 16.7 ms
-- frame even in the worst case. Measured on this machine, a full probe is
-- ~33 us, but the result is cached per HWND, so a sample while the foreground
-- window is unchanged (the overwhelmingly common case while gaming) is
-- ~0.008 us. At 1 Hz that is ~0.000001% of one core. History is run-length
-- encoded, so an hour of sitting in one game is a single table entry.

local ok_obs, obslua_mod = pcall(function() return obslua end)
obs = ok_obs and obslua_mod or nil

-- ---------------------------------------------------------------- tuning ---

local SAMPLE_MS = 1000          -- how often focus is polled
local SAMPLE_GAP_MAX = 5        -- max seconds between samples still treated as one span
local HISTORY_SECONDS = 60 * 60 -- how much focus history to retain
local DEFAULT_REPLAY_SECONDS = 120
local FULLSCREEN_WEIGHT = 2.0   -- fullscreen is a strong "this is the content" signal
local WINDOWED_WEIGHT = 1.0

-- Shell / desktop surfaces. Never a clip subject; folder falls back to "Desktop".
local DESKTOP_APPS = {
    explorer = true, searchhost = true, searchapp = true,
    startmenuexperiencehost = true, shellexperiencehost = true,
    applicationframehost = true, dwm = true, lockapp = true,
    textinputhost = true, systemsettings = true,
}

-- Apps you pass *through* on the way to saving a clip. They only decide the
-- folder if literally nothing else was focused during the clip.
local OVERLAY_APPS = {
    discord = true, obs64 = true, obs = true, steam = true,
    steamwebhelper = true, epicgameslauncher = true, taskmgr = true,
    spotify = true, nvidia_share = true, overwolf = true,
    gameoverlayui = true, teamspeak3 = true, slack = true,
}

-- ------------------------------------------------- pure scoring (testable) ---

-- History is run-length encoded: each span is {exe, w, t0, t1} covering a
-- contiguous stretch of focus. Staying in one game for an hour is one span,
-- so memory is O(number of alt-tabs), not O(seconds).
local M = { spans = {} }
OBS_CLIP_SORT = M

function M.sanitize(name)
    return (name:gsub('[<>:"/\\|%?%*]', ""))
end

function M.classify(exe)
    local key = exe:lower()
    if DESKTOP_APPS[key] then return "desktop" end
    if OVERLAY_APPS[key] then return "overlay" end
    return "content"
end

function M.record(exe, weight, t)
    if not exe then return end
    weight = weight or WINDOWED_WEIGHT
    local last = M.spans[#M.spans]
    if last and last.exe == exe and last.w == weight and t - last.t1 <= SAMPLE_GAP_MAX then
        last.t1 = t                 -- extend the current span, no allocation
    else
        M.spans[#M.spans + 1] = { exe = exe, w = weight, t0 = t, t1 = t }
    end

    -- Drop spans that fell entirely out of the retention window.
    local cutoff = t - HISTORY_SECONDS
    if M.spans[1].t1 < cutoff then
        local keep = {}
        for i = 1, #M.spans do
            if M.spans[i].t1 >= cutoff then keep[#keep + 1] = M.spans[i] end
        end
        M.spans = keep
    end
end

-- Pick the folder from focus spans overlapping [since, now].
-- Tiers: real content apps win; overlay apps only if nothing else; else nil.
function M.folder_for_window(since, now)
    local score, tier = {}, {}
    for i = 1, #M.spans do
        local s = M.spans[i]
        local a = s.t0 > since and s.t0 or since
        local b = s.t1 < now and s.t1 or now
        if b >= a then
            -- A span covering [t0, t1] represents t1 - t0 + 1 one-second samples.
            score[s.exe] = (score[s.exe] or 0) + (b - a + 1) * s.w
            tier[s.exe] = M.classify(s.exe)
        end
    end

    for _, want in ipairs({ "content", "overlay" }) do
        local best, best_score = nil, -1
        for exe, sc in pairs(score) do
            if tier[exe] == want and sc > best_score then
                best, best_score = exe, sc
            end
        end
        if best then return M.sanitize(best) end
    end
    return nil
end

-- ------------------------------------------------------ win32 focus probe ---

local user32, kernel32
if obs then
    local ffi = require("ffi")
    ffi.cdef[[
    typedef void* HWND;
    typedef void* HANDLE;
    typedef unsigned long DWORD;
    typedef struct { long left, top, right, bottom; } RECT;
    HWND GetForegroundWindow();
    DWORD GetWindowThreadProcessId(HWND hWnd, DWORD* lpdwProcessId);
    HANDLE OpenProcess(DWORD dwDesiredAccess, int bInheritHandle, DWORD dwProcessId);
    int QueryFullProcessImageNameA(HANDLE hProcess, DWORD dwFlags, char* lpExeName, DWORD* lpdwSize);
    int CloseHandle(HANDLE hObject);
    int CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes);
    int GetWindowRect(HWND hWnd, RECT* lpRect);
    int GetSystemMetrics(int nIndex);
    ]]
    user32   = ffi.load("user32")
    kernel32 = ffi.load("kernel32")

    -- Resolving a PID to an exe name costs ~33 us and is the only expensive
    -- part, so cache it per HWND: while you sit in one game every sample is a
    -- pointer compare. The fullscreen check is re-measured each sample because
    -- it is nearly free (~0.05 us including GetForegroundWindow) and a game can
    -- toggle fullscreen without its window handle changing.
    local cached_hwnd, cached_exe = nil, nil
    local buf  = ffi.new("char[512]")           -- reused, so sampling never allocates
    local size = ffi.new("DWORD[1]")
    local pid  = ffi.new("DWORD[1]")
    local rect = ffi.new("RECT[1]")

    local function exe_for(hwnd)
        user32.GetWindowThreadProcessId(hwnd, pid)
        if pid[0] == 0 then return nil end
        local h = kernel32.OpenProcess(0x1000, 0, pid[0])  -- PROCESS_QUERY_LIMITED_INFORMATION
        if h == nil then return nil end
        size[0] = 512
        local ok = kernel32.QueryFullProcessImageNameA(h, 0, buf, size)
        kernel32.CloseHandle(h)
        if ok == 0 then return nil end
        local full = ffi.string(buf, size[0])
        return full:match("([^\\/]+)%.[eE][xX][eE]$") or full:match("([^\\/]+)$")
    end

    -- Does the window cover the primary monitor, within a small tolerance?
    local function fullscreen_weight(hwnd)
        if user32.GetWindowRect(hwnd, rect) == 0 then return WINDOWED_WEIGHT end
        local sw, sh = user32.GetSystemMetrics(0), user32.GetSystemMetrics(1)
        local ww = rect[0].right - rect[0].left
        local wh = rect[0].bottom - rect[0].top
        if sw > 0 and sh > 0 and ww >= sw * 0.95 and wh >= sh * 0.90 then
            return FULLSCREEN_WEIGHT
        end
        return WINDOWED_WEIGHT
    end

    function M.foreground_info()
        local hwnd = user32.GetForegroundWindow()
        if hwnd == nil then return nil end
        if hwnd ~= cached_hwnd then
            cached_hwnd, cached_exe = hwnd, exe_for(hwnd)
        end
        if not cached_exe then return nil end
        return cached_exe, fullscreen_weight(hwnd)
    end
end

M.now = function() return os.time() end

function sample_tick()
    local exe, weight = M.foreground_info()
    M.record(exe, weight, M.now())
end

-- Folder for a clip covering the last `seconds`, with live-probe fallback.
function M.folder_for_clip(seconds)
    local now = M.now()
    local folder = M.folder_for_window(now - seconds, now)
    if folder then return folder end
    local exe = M.foreground_info()
    if exe and M.classify(exe) ~= "desktop" then return M.sanitize(exe) end
    return "Desktop"
end

-- ------------------------------------------------------- OBS integration ---

local restarting = false
local rec_start_t = nil

local function replay_seconds()
    local ok, secs = pcall(function()
        local out = obs.obs_frontend_get_replay_buffer_output()
        if out == nil then return nil end
        local st = obs.obs_output_get_settings(out)
        local v = nil
        if st ~= nil then
            v = obs.obs_data_get_int(st, "max_time_sec")
            obs.obs_data_release(st)
        end
        obs.obs_output_release(out)
        return v
    end)
    if ok and secs and secs > 0 then return secs end
    return DEFAULT_REPLAY_SECONDS
end

M.move_to_folder = function(path, folder)
    if not path or path == "" or not folder or folder == "" then return end
    local dir, file = path:match("^(.*)[/\\]([^/\\]+)$")
    if not dir then return end
    local target = dir .. "\\" .. folder
    kernel32.CreateDirectoryA(target, nil)   -- no-op if it exists
    -- os.rename fails if the destination exists (two saves with the same
    -- timestamp-derived name), which used to strand the clip in Videos\.
    -- Pick a free name instead: "clip (2).mp4", "clip (3).mp4", ...
    local stem, ext = file:match("^(.*)(%.[^.]+)$")
    if not stem then stem, ext = file, "" end
    local name, n = file, 1
    while true do
        local fh = io.open(target .. "\\" .. name, "rb")
        if not fh then break end
        fh:close()
        n = n + 1
        name = stem .. " (" .. n .. ")" .. ext
    end
    local ok, err = os.rename(path, target .. "\\" .. name)
    if ok then
        print("sorted -> " .. folder .. "\\" .. name)
    else
        print("move failed: " .. tostring(err))
    end
end

function do_start()
    obs.timer_remove(do_start)
    obs.obs_frontend_replay_buffer_start()
end

function do_stop()
    obs.timer_remove(do_stop)
    obs.obs_frontend_replay_buffer_stop()
end

function on_event(event)
    if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        -- Only footage actually inside the clip should decide the folder.
        M.move_to_folder(obs.obs_frontend_get_last_replay(),
                         M.folder_for_clip(replay_seconds()))
        restarting = true
        obs.timer_add(do_stop, 100)
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED and restarting then
        restarting = false
        obs.timer_add(do_start, 500)
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        rec_start_t = M.now()
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        local span = rec_start_t and (M.now() - rec_start_t) or DEFAULT_REPLAY_SECONDS
        M.move_to_folder(obs.obs_frontend_get_last_recording(), M.folder_for_clip(span))
        rec_start_t = nil
    end
end

function script_load(settings)
    obs.obs_frontend_add_event_callback(on_event)
    obs.timer_add(sample_tick, SAMPLE_MS)
    sample_tick()
    print("replay-flush + smart game-sort loaded")
end

function script_unload()
    obs.timer_remove(sample_tick)
end

function script_description()
    return "Flush the replay buffer after each save (no overlap) and sort clips/recordings " ..
           "into per-game folders using the app that held focus for most of the clip " ..
           "(ignores Discord/Steam/shell pass-throughs)."
end
```

### test-obs-sort.lua

```lua
-- Tests for obs-replay-flush.lua clip-folder scoring. Run: lua test-obs-sort.lua
-- No OBS required: the script skips the win32 layer when `obslua` is absent.

local dir = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
assert(loadfile(dir .. "/obs-replay-flush.lua"))()
local M = OBS_CLIP_SORT

-- Virtual clock + fake foreground window.
local clock = 1000000
local fg = { exe = "explorer", w = 1.0 }
M.now = function() return clock end
M.foreground_info = function() return fg.exe, fg.w end

local function focus(exe, secs, w)
    fg.exe, fg.w = exe, w or 1.0
    for _ = 1, secs do clock = clock + 1; sample_tick() end
end

local function reset()
    M.spans = {}
    fg.exe, fg.w = "explorer", 1.0
end

local pass, fail = 0, 0
local function check(name, got, expect)
    if got == expect then
        pass = pass + 1
        print("PASS  " .. name)
    else
        fail = fail + 1
        print("FAIL  " .. name .. "  expected=" .. tostring(expect) .. " got=" .. tostring(got))
    end
end

local CLIP = 120  -- replay buffer length used by these cases

-- 1) Start on the desktop, launch a game, save. The game wins.
reset()
focus("explorer", 20)
focus("FortniteClient-Win64-Shipping", 100, 2.0)
check("desktop then game -> game", M.folder_for_clip(CLIP), "FortniteClient-Win64-Shipping")

-- 2) Play the game, alt-tab to Discord, save. Discord is a pass-through.
reset()
focus("FortniteClient-Win64-Shipping", 100, 2.0)
focus("Discord", 8)
check("discord pass-through ignored", M.folder_for_clip(CLIP), "FortniteClient-Win64-Shipping")

-- 3) Only Discord in the clip window -> Discord is legitimately the subject.
reset()
focus("Discord", 200)
check("only discord -> Discord", M.folder_for_clip(CLIP), "Discord")

-- 4) Only shell activity -> Desktop.
reset()
focus("explorer", 200)
check("only shell -> Desktop", M.folder_for_clip(CLIP), "Desktop")

-- 5) An older game outside the clip window must not win.
reset()
focus("eldenring", 300, 2.0)
focus("FortniteClient-Win64-Shipping", 110, 2.0)
check("older game outside window ignored", M.folder_for_clip(CLIP), "FortniteClient-Win64-Shipping")

-- 6) Two content apps inside the window: most focus time wins.
reset()
focus("Notepad", 30)
focus("SonsOfTheForest", 80, 2.0)
check("most-focused content app wins", M.folder_for_clip(CLIP), "SonsOfTheForest")

-- 7) Fullscreen weighting breaks a tie in equal wall-clock time.
reset()
focus("Notepad", 50)
focus("eldenring", 50, 2.0)
check("fullscreen outweighs windowed at equal time", M.folder_for_clip(CLIP), "eldenring")

-- 8) No samples at all -> live probe fallback.
reset()
fg.exe, fg.w = "eldenring", 2.0
check("no history falls back to live probe", M.folder_for_clip(CLIP), "eldenring")

-- 9) No samples and shell focused -> Desktop.
reset()
fg.exe, fg.w = "explorer", 1.0
check("no history + shell -> Desktop", M.folder_for_clip(CLIP), "Desktop")

-- 10) Illegal path characters are stripped from the folder name.
reset()
focus('Weird:Game*Name', 100)
check("sanitizes folder name", M.folder_for_clip(CLIP), "WeirdGameName")

-- 11) A long recording spans its whole duration, so the game still wins.
reset()
focus("explorer", 60)
focus("SpeciesUnknown-Win64-Shipping", 600, 2.0)
focus("Discord", 20)
check("long recording -> game", M.folder_for_clip(700), "SpeciesUnknown-Win64-Shipping")

-- 12) Run-length encoding: a long uninterrupted session is one span.
reset()
focus("eldenring", 3000, 2.0)
check("uninterrupted session is 1 span", #M.spans, 1)

-- 13) Each alt-tab creates a span, so memory tracks alt-tabs, not seconds.
reset()
for _ = 1, 5 do
    focus("eldenring", 100, 2.0)
    focus("Discord", 5)
end
check("10 alt-tabs -> 10 spans", #M.spans, 10)

-- 14) Retention bounds memory even across a very long session.
reset()
for _ = 1, 200 do
    focus("eldenring", 30, 2.0)
    focus("Discord", 30)
end
local bounded = #M.spans <= 260   -- 1 h retention at >=30 s per span
check("history stays bounded", bounded, true)
check("still sorts correctly after long session", M.folder_for_clip(CLIP), "eldenring")

-- 15) A gap in sampling (OBS busy / machine asleep) splits the span rather
--     than silently crediting the missing time to whatever was last focused.
reset()
focus("eldenring", 50, 2.0)
clock = clock + 600          -- 10 minute gap with no samples
focus("eldenring", 50, 2.0)
check("sampling gap splits the span", #M.spans, 2)
check("gap time is not credited", M.folder_for_window(clock - 100, clock), "eldenring")

-- 16) Fullscreen toggling mid-session splits spans but keeps the same winner.
reset()
focus("eldenring", 40, 1.0)
focus("eldenring", 40, 2.0)
check("weight change splits span", #M.spans, 2)
check("same app still wins across toggle", M.folder_for_clip(CLIP), "eldenring")

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
```

### test-obs-win32.lua

```lua
-- Smoke test for the OBS/win32 branch of obs-replay-flush.lua.
-- Requires LuaJIT (ffi) on Windows. Stubs the obslua frontend API, then drives
-- a real save event end to end with the move intercepted.
local ok_ffi = pcall(require, "ffi")
if not ok_ffi then
    print("SKIP: needs LuaJIT with ffi (OBS ships one). Run under luajit.")
    os.exit(0)
end

local timers = {}
obslua = {
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED = 1,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED = 2,
    OBS_FRONTEND_EVENT_RECORDING_STARTED = 3,
    OBS_FRONTEND_EVENT_RECORDING_STOPPED = 4,
    obs_frontend_add_event_callback = function() end,
    timer_add = function(f, ms) timers[#timers + 1] = { f = f, ms = ms } end,
    timer_remove = function() end,
    obs_frontend_replay_buffer_start = function() end,
    obs_frontend_replay_buffer_stop = function() end,
    obs_frontend_get_replay_buffer_output = function() return nil end,   -- forces the default length
    obs_frontend_get_last_replay = function() return "C:\\Users\\blare\\Videos\\clip.mp4" end,
    obs_frontend_get_last_recording = function() return "C:\\Users\\blare\\Videos\\rec.mp4" end,
}

local dir = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
assert(loadfile(dir .. "/obs-replay-flush.lua"))()
local M = OBS_CLIP_SORT

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print("PASS  " .. name)
    else fail = fail + 1; print("FAIL  " .. name .. "  " .. tostring(detail)) end
end

-- The real win32 probe must return this process's foreground window owner.
local exe, w = M.foreground_info()
check("win32 probe returns an exe name", type(exe) == "string" and #exe > 0, exe)
check("win32 probe returns a weight", w == 1.0 or w == 2.0, w)

-- Caching must be stable and must not leak: repeated probes agree.
local exe2 = M.foreground_info()
check("probe is stable across calls", exe2 == exe, exe2)

-- Sampling must not allocate unboundedly: 5000 ticks on one window = 1 span.
M.spans = {}
local t = 1000000
M.now = function() return t end
for _ = 1, 5000 do t = t + 1; sample_tick() end
check("5000 real samples -> 1 span", #M.spans == 1, #M.spans)

-- Drive a full save event with the move intercepted.
local moved_to
M.move_to_folder = function(path, folder) moved_to = folder end
on_event(obslua.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED)
check("save event produced a folder", type(moved_to) == "string" and #moved_to > 0, moved_to)
check("save event scheduled buffer restart", #timers > 0, #timers)

-- Recording path.
on_event(obslua.OBS_FRONTEND_EVENT_RECORDING_STARTED)
t = t + 300
on_event(obslua.OBS_FRONTEND_EVENT_RECORDING_STOPPED)
check("recording event produced a folder", type(moved_to) == "string" and #moved_to > 0, moved_to)

print(string.format("\n%d passed, %d failed  (foreground was: %s)", pass, fail, exe))
os.exit(fail == 0 and 0 or 1)
```

### test-obs-collision.lua

```lua
-- Regression test: two saves with the same name must both get sorted.
-- Run: luajit test-obs-collision.lua   (needs ffi, like test-obs-win32.lua)
local ok_ffi = pcall(require, "ffi")
if not ok_ffi then print("SKIP: needs LuaJIT"); os.exit(0) end

obslua = {
    obs_frontend_add_event_callback = function() end,
    timer_add = function() end, timer_remove = function() end,
}
local dir = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
assert(loadfile(dir .. "/obs-replay-flush.lua"))()
local M = OBS_CLIP_SORT

local root = os.getenv("TEMP") .. "\\obs-collision-" .. os.time()
os.execute('mkdir "' .. root .. '"')
local function write(p, s) local f = assert(io.open(p, "wb")); f:write(s); f:close() end
local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end

local pass, fail = 0, 0
local function check(name, cond) if cond then pass = pass + 1; print("PASS  " .. name) else fail = fail + 1; print("FAIL  " .. name) end end

local clip = root .. "\\rb Sep 21 09.14 PM.mp4"
write(clip, "first");  M.move_to_folder(clip, "Game")
write(clip, "second"); M.move_to_folder(clip, "Game")
write(clip, "third");  M.move_to_folder(clip, "Game")

check("first keeps original name",  read(root .. "\\Game\\rb Sep 21 09.14 PM.mp4") == "first")
check("second gets (2)",            read(root .. "\\Game\\rb Sep 21 09.14 PM (2).mp4") == "second")
check("third gets (3)",             read(root .. "\\Game\\rb Sep 21 09.14 PM (3).mp4") == "third")
check("nothing stranded in root",   read(clip) == nil)

os.execute('rmdir /s /q "' .. root .. '"')
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
```
