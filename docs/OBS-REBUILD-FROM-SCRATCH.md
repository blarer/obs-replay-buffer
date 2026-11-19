# Rebuild Guide: Always-On OBS Replay Buffer, Close Notification, Clip Sorting

> **Superseded.** `setup.ps1` in the repo root does all of this automatically. This document is kept for the reasoning behind each piece and as a manual fallback. Paths below use the original layout; in the repo, tests live in `tests/` and the classifier in `tools/`.

Written 2026-09-24 for an AI (or human) with **no memory** of the original work. Follow it top to bottom on a fresh Windows 11 PC and you get the exact same setup. Every value was read off the working machine, not guessed. The full source of every file is in the **Appendix**, so this file alone is enough even if `C:\Users\<you>\obs-replay-buffer` is gone.

A picture of the whole flow: `OBS-flow.png` (source `OBS-flow.mmd`, render command in section 6).

---

## 0. What the finished system does

1. You log in. About 30 s later OBS starts **silently in the tray** with the **replay buffer running**. No window, no prompt.
2. The buffer holds the last 10 minutes in RAM. **Alt+Z** saves it.
3. The clip is moved into a per-game folder, e.g. `Videos\FortniteClient-Win64-Shipping\`, chosen by which app **had focus for most of the clip** (not whatever is on top at save time). Name clashes get ` (2)`, ` (3)`.
4. After every save the buffer restarts once, so the next clip never repeats footage.
5. If the buffer is ever off while OBS is open, it is turned back on within ~1 s (measured 1.3 s).
6. If you close OBS (or it crashes), within 1 minute a notification appears: **"OBS closed - replay buffer is OFF"**:
   - **Relaunch now**: starts OBS right away.
   - **Stay off 5 min**: quiet for 5 minutes, then the notification comes back.
   - **X / ignore**: after 5 minutes OBS restarts by itself. Recording can never be forgotten.
7. Relaunches after a crash start straight into normal mode (no "Run in Safe Mode?" popup).

## 1. How it fits together

```
Task Scheduler "OBS Replay Buffer Watchdog"  (at logon +30 s, then every 1 min)
  -> wscript obs-watchdog-gate.vbs                   ~30 ms CPU
       OBS running AND state says nothing pending?  -> exit   (almost every minute)
       otherwise (or any error)                     -> powershell obs-replay-watchdog.ps1  (~280 ms)
            OBS off, new boot          -> launch silently
            OBS off, just closed       -> save 5 min timer, THEN show toast
            OBS off, timer expired     -> relaunch
            OBS off, snoozed           -> wait
            OBS on                     -> tidy state, remove stale toast
Toast buttons -> obs-watchdog: URL (HKCU) -> run-hidden.vbs -> obs-watchdog-action.ps1
Every launch  -> delete stale OBS crash markers -> obs64 --startreplaybuffer --minimize-to-tray
Inside OBS    -> obs-replay-flush.lua, 1 Hz: focus history + keep the buffer on
                 on save: sort into Videos\<exe>\, restart buffer once
obs-watchdog-common.ps1   all shared logic (both .ps1 files dot-source it)
obs-watchdog-state.json   lastSeenBoot / graceUntil / snoozeUntil
obs-watchdog.log          one line per real action, nothing on quiet runs, rotates at 256 KB
```

Why it is built this way:
- **Task Scheduler every minute**, not a resident loop: nothing stays in memory, and it survives crashes, sleep and reboots.
- **The VBS gate**: starting PowerShell costs ~280 ms CPU (measured). In steady state there is nothing to do, so a ~30 ms VBScript check answers "OBS running and nothing pending?" and exits. It **fails open**: any doubt or error runs the full watchdog, so it can only save work, never skip it.
- **wscript, not powershell, as the task action**: a task that starts powershell.exe flashes a console window every minute even with `-WindowStyle Hidden`.
- **Boot time in the state file** tells "PC just booted" (launch silently) apart from "user closed OBS" (ask first). It is stored as the raw WMI string (e.g. `20260924085141.500000-240`) so VBScript and PowerShell compare it identically.
- **Protocol URL for the toast buttons**: a toast shown from PowerShell can't run code. A button can only open a URL, so `obs-watchdog:` is registered to call a script.
- **The keep-alive lives inside OBS (Lua)**, not outside via obs-websocket. It is faster (1 s vs 1 min), needs no password, and the websocket server can stay off.
- **Core rule**: never lose a clip to an unanswered prompt, but always allow turning OBS off on purpose.

---

## 2. Step by step build

User on the original machine: `<you>`. Scripts live in the cloned repo folder, e.g. `C:\Users\<you>\obs-replay-buffer\`.

### Step 1. Install OBS
OBS Studio 32.x (original: 32.2.0) at `C:\Program Files\obs-studio\`. Run it once normally so `%APPDATA%\obs-studio\` exists. Do **not** set it to run as administrator (section 3).

### Step 2. Profile `GameRec-AV1`
Profile -> New -> `GameRec-AV1`. OBS stores it in `%APPDATA%\obs-studio\basic\profiles\GameRecAV1\` (hyphen dropped, normal).

Settings -> Output -> Output Mode **Advanced**, Recording tab:

| Setting | Value |
|---|---|
| Type | Standard |
| Recording Path | `C:\Users\<user>\Videos` |
| Recording Format | **Hybrid MP4** (crash-safe like MKV, plays everywhere like MP4) |
| Audio Track | 1 and 2 |
| Video Encoder | **NVIDIA NVENC AV1** (`obs_nvenc_av1_tex`) |
| Rescale Output | off |
| Rate Control | **CQP**, CQ Level **20** |
| Keyframe Interval | 2 s |
| Preset | **P7** |
| Tuning | High Quality |
| Multipass | Disabled |
| Profile | main |
| Look-ahead | off |
| Adaptive Quantization | on |
| B-frames | 2 |

Audio tab: Track 1 and 2 at **320 kbps** (FFmpeg AAC).
Replay Buffer tab: enabled, Max time **600 s**, Max memory **4096 MB**, prefix `rb`. Measured: a full Fortnite buffer is 600 s at ~3 GB (~42 Mbps), so the time limit binds and 4 GB is headroom.
Filename formatting: `%b %d %I.%M %p` (e.g. `rb Sep 23 10.08 PM.mp4`). Same-minute clashes are handled by the Lua ` (2)` suffix.
Video: base and output **2560x1440**, **60 FPS**. Advanced: NV12, 709, Partial, Direct3D 11. Audio: 48 kHz stereo, audio ducking disabled.
Hotkeys: **Replay Buffer -> Save Replay = Alt+Z**, Hotkey focus behavior **Never disable hotkeys**.
General: system tray enabled.

### Step 3. Sources (scene collection "Untitled")
One scene with **Game Capture** (`game_capture`), mode "Capture specific window", window `Fortnite :UnrealWindow:FortniteClient-Win64-Shipping.exe`. Not Display Capture (it duplicates the whole desktop). Audio: Desktop Audio (+2) and Mic/Aux (+2) on your devices.

### Step 4. obs-websocket: not needed
Nothing in this setup uses it. Leave it off (Tools -> WebSocket Server Settings -> uncheck Enable), unless some other tool of yours needs it.

### Step 5. Scripts
Write these into `C:\Users\<user>\Scripts\` exactly as in the Appendix:
- `obs-watchdog-common.ps1`, `obs-replay-watchdog.ps1`, `obs-watchdog-action.ps1`
- `obs-watchdog-gate.vbs`, `run-hidden.vbs`
- `obs-replay-flush.lua`
- tests: `test-watchdog.ps1`, `test-gate.ps1`, `test-obs-sort.lua`, `test-obs-win32.lua`, `test-obs-collision.lua`, `test-obs-keepalive.lua`

Keep `.ps1` files plain ASCII (PowerShell 5.1 misreads UTF-8 without BOM). `obs-watchdog-state.json` and `obs-watchdog.log` are created automatically. If the OBS path differs, change `$ObsExe` in `obs-watchdog-common.ps1`.

### Step 6. Load the Lua script
OBS -> Tools -> Scripts -> `+` -> `obs-replay-flush.lua`. Script Log shows `replay-flush + smart game-sort loaded`. After edits press the reload button, no OBS restart needed.

### Step 7. Register the `obs-watchdog:` protocol (per user, HKCU, no admin)
```powershell
$u = "C:\Users\$env:USERNAME\Scripts"
$k = 'HKCU:\Software\Classes\obs-watchdog'
New-Item "$k\shell\open\command" -Force | Out-Null
Set-ItemProperty $k '(default)' 'URL:OBS Watchdog Protocol'
Set-ItemProperty $k 'URL Protocol' ''
Set-ItemProperty "$k\shell\open\command" '(default)' "wscript.exe `"$u\run-hidden.vbs`" `"$u\obs-watchdog-action.ps1`" `"%1`""
```

### Step 8. Scheduled task
Must run as the **logged-in user, interactive, not "highest privileges", not SYSTEM**, or the toast is invisible and OBS starts in the wrong session.
```powershell
$u   = "C:\Users\$env:USERNAME\Scripts"
$act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$u\obs-watchdog-gate.vbs`""
$t1  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$t1.Delay = 'PT30S'
$t2  = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
         -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
         -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
$pr  = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Register-ScheduledTask 'OBS Replay Buffer Watchdog' -Action $act -Trigger $t1,$t2 -Settings $set -Principal $pr
```
Or import `obs-watchdog-task.xml` (fix the user inside first on a new PC).

### Step 9. Verify
Automated (no OBS changes, temp folders only):
```
powershell -NoProfile -ExecutionPolicy Bypass -File test-watchdog.ps1   -> 42 passed
powershell -NoProfile -ExecutionPolicy Bypass -File test-gate.ps1       -> 13 passed (needs OBS open)
lua test-obs-sort.lua                                                   -> 19 passed
luajit test-obs-win32.lua                                               -> 7 passed
luajit test-obs-collision.lua                                           -> 4 passed
lua test-obs-keepalive.lua                                              -> 21 passed
```
(`scoop install lua luajit` for the Lua runners.)

Live, all done on the original machine 2026-09-24, each visible in `obs-watchdog.log` or the OBS log:
1. Kill OBS -> toast within 1 min (12:17:02) -> X -> relaunched exactly 5 min later (12:22:02).
2. Kill OBS again -> relaunch logs `cleared 2 crash marker(s)` -> OBS starts in normal mode, no Safe Mode popup, Lua loaded, buffer started.
3. Stop the buffer while OBS runs -> Lua `keep-alive: replay buffer was off, starting it` -> running again after 1.3 s.
4. Save -> `sorted -> <folder>\<file>` -> buffer Stop/Start exactly once, no keep-alive interference.
5. Steady state: gate ~31 ms CPU and no PowerShell started.

---

## 3. Settings for the cleanest resource use (and why)

Evidence (OBS log, 1.5 h of buffer while gaming): **32 of 334,977 frames skipped for encoding lag (0.0%)**, 32 for rendering lag (0.0%), GPU encode median 0.088 ms. Hardware: RTX 5090-class GPU, AMD X3D CPU, 1440p ~480 Hz OLED, 63.6 GB RAM.

| Choice | Why |
|---|---|
| NVENC hardware encoder | Separate video engine, not CUDA cores or CPU. x264 would take CPU from the game. |
| AV1 | Smallest files at equal quality. Needs RTX 40 or newer, else NVENC HEVC. |
| CQP 20 | Constant quality for local clips (not for streaming). |
| Preset P7 | Slowest preset, still 0.0% skipped here. If "skipped frames due to encoding lag" ever appears, drop to P5 first. |
| Look-ahead off, multipass off | Extra GPU work for little gain at CQP. |
| Native 1440p, no rescale | Scaling costs render time. |
| 60 FPS | Encoding at the game's ~480 fps would multiply encoder work. |
| Game Capture | Hooks only the game, not the whole desktop. |
| RAM buffer | No constant disk writes. ~3 GB when full. Shortening to 3 min would free ~2 GB, not worth it with 63.6 GB. |
| OBS not admin, priority Normal | The log line `D3D11 GPU priority setup failed (not admin?)` is intentional. As admin OBS raises its GPU priority and can take frame time from the game. |
| Lua sampler at 1 Hz, cached per window | ~0.008 us steady, ~33 us on window change. Lua timers run on OBS's video tick (render thread), so it is cheap because it is tiny, not because of which thread. |
| VBS gate every minute | ~31 ms CPU vs ~280 ms for PowerShell. ~45 s CPU/day instead of ~7 min. |

Trade-off: the 24/7 buffer keeps one NVENC session and ~3 GB RAM busy. A Fortnite tuning pass listed it as the top A/B candidate for 1% lows; the user chose to keep it. To A/B: `Disable-ScheduledTask 'OBS Replay Buffer Watchdog'`, close OBS, compare, `Enable-ScheduledTask`.

---

## 4. History

1. **2026-07-03/04**: original build (Claude Code, transcript gone): profile, watchdog, toast + protocol, task, `run-hidden.vbs`, first Lua flush script (single foreground snapshot).
2. **2026-08-05/06** (jcode "fish"): Lua rewritten into the focus-over-time sampler + tests.
3. **2026-09-13** (Claude Code e629dab1): profile found broken (720p30, buffer off), rebuilt as `GameRec-AV1`. Left an orphan folder `profiles\GameRec-AV1\` (hyphen) that OBS does not use. The live one is `GameRecAV1`.
4. **2026-09-22** (jcode optimization swarm): read-only audit. Capture switched from Display Capture to Game Capture.
5. **2026-09-24**: docs written; then a robustness + lean pass:
   - Name-clash fix: second same-minute save used to be stranded in `Videos\` (`rb Sep 21 09.14 PM.mp4`).
   - Bug: if the toast failed, the old script died before saving the 5 min timer, so OBS was **never** relaunched. Now the timer is saved first.
   - Bug: OBS 32 removed `--disable-shutdown-check`, so any relaunch after a crash stopped at the Safe Mode popup (seen live). Now stale crash markers are cleared before launch.
   - Keep-alive moved into Lua; websocket code, password read and SHA256 auth removed.
   - VBS gate added; state writes made atomic and locked; action log added; old boot-time format migrated automatically.

---

## 5. Gotchas an AI must not get wrong

- **Never** run the task as SYSTEM or with highest privileges.
- Register the protocol under **HKCU\Software\Classes**, not HKLM.
- The toast AppID must be registered with Windows; this borrows PowerShell's. A made-up one fails silently.
- **Stay off** snoozes then asks again. **Ignoring** relaunches after 5 min. Different paths, on purpose.
- **OBS 32 has no `--disable-shutdown-check`.** An unclean exit leaves `%APPDATA%\obs-studio\.sentinel\run_<uuid>`, and the next start blocks on "Run in Safe Mode?" before loading anything. Clear `run_*` files only when obs64 is **not** running. Safe Mode would also disable scripting, i.e. the Lua sorter and keep-alive.
- The Lua keep-alive must stay hands-off during: the first 15 s after load (OBS starts the buffer itself), the post-save flush, and OBS exit. Otherwise it double-starts or fights shutdown.
- VBScript under `On Error Resume Next`: an error **inside an If condition runs the Then branch**, the setting does **not** carry into functions, and `RegExp` needs `Global = True` to see duplicates. All three caused real bugs while writing the gate.
- PowerShell: `[IO.File]::Replace(a, b, $null)` fails ("path is not of a legal form") because `$null` becomes `""`; use `[NullString]::Value`. Never name a parameter `$args`.
- Folders are named after the **exe**, not a pretty title.

---

## 6. Re-render the flow chart

```
set PUPPETEER_SKIP_DOWNLOAD=1
npx -y -p @mermaid-js/mermaid-cli@11 mmdc -i OBS-flow.mmd -o %USERPROFILE%\Desktop\OBS-flow.png -p edge.json -b white -w 1800 -s 1.5
```
with `edge.json` = `{ "executablePath": "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe", "args": ["--no-sandbox"] }` (uses installed Edge, no Chromium download).

---

## Appendix: full source of every file

### obs-watchdog-common.ps1

````powershell
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

$WatchdogDir = if ($env:OBS_WATCHDOG_STATEDIR) { $env:OBS_WATCHDOG_STATEDIR } else { $PSScriptRoot }
$StateFile   = Join-Path $WatchdogDir 'obs-watchdog-state.json'
$LogFile     = Join-Path $WatchdogDir 'obs-watchdog.log'

$ObsExe        = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe'
$ObsDir        = Split-Path $ObsExe
$GraceMinutes  = 5
$SnoozeMinutes = 5
$LogMaxBytes   = 256KB
# Toasts need an AppID Windows already knows. This is PowerShell's own.
$ToastAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

# ------------------------------------------------------------ environment ---
# Small wrappers so tests can replace them.

function Get-Now { Get-Date }

function Get-BootId { [string](Get-WmiObject Win32_OperatingSystem).LastBootUpTime }

function Test-ObsRunning { [bool](Get-Process obs64 -ErrorAction SilentlyContinue) }

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

function New-State { [ordered]@{ lastSeenBoot = ''; snoozeUntil = ''; graceUntil = '' } }

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
    param($State, [string]$Boot, [bool]$ObsRunning, [datetime]$Now)

    $s = New-State
    foreach ($k in @($s.Keys)) { $s[$k] = [string]$State[$k] }

    if ($ObsRunning) {
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
                -ObsRunning (Test-ObsRunning) -Now (Get-Now)
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
````

### obs-replay-watchdog.ps1

````powershell
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
````

### obs-watchdog-action.ps1

````powershell
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
````

### obs-watchdog-gate.vbs

````vb' OBS watchdog gate. Task Scheduler runs this every minute instead of starting
' PowerShell directly. PowerShell costs ~350 ms CPU per start. This check
' costs ~25 ms, and almost every minute it finds nothing to do.
'
' It exits quietly ONLY when all of these are true:
'   1. obs64.exe is running
'   2. the state file says this boot was already handled (lastSeenBoot matches)
'   3. no toast is pending and no snooze is set (graceUntil and snoozeUntil empty)
' In every other case, including ANY error here, it runs obs-replay-watchdog.ps1
' exactly as before (fail-open), so the gate can only save work, never skip it.
'
' The state file is written by the .ps1 as JSON with fixed field names. The
' values checked here are plain strings, so a simple pattern match is enough.
Option Explicit
On Error Resume Next

Dim fso, dir, stateFile, ps1, sh, testDir
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = dir & "\obs-replay-watchdog.ps1"
stateFile = dir & "\obs-watchdog-state.json"
' Test hook (test-gate.ps1): read state from a temp dir, report instead of run.
testDir = sh.ExpandEnvironmentStrings("%OBS_WATCHDOG_STATEDIR%")
If testDir <> "%OBS_WATCHDOG_STATEDIR%" And testDir <> "" Then
    stateFile = testDir & "\obs-watchdog-state.json"
End If

' Never call CanSkip inside an If: see the trap described below.
' Exit codes 10/20 exist only for test-gate.ps1. Normal runs always exit 0,
' so Task Scheduler's "Last Run Result" stays 0x0 (success).
Dim skip, testing
testing = (testDir <> "%OBS_WATCHDOG_STATEDIR%" And testDir <> "")
skip = False
skip = CanSkip()
If Err.Number <> 0 Then skip = False
If testing Then
    If skip = True Then WScript.Quit 10
    WScript.Quit 20
End If
If skip = True Then WScript.Quit 0
RunWatchdog
WScript.Quit 0

' VBScript traps (both caused real bugs while writing this):
'  1. Under "On Error Resume Next", an error INSIDE an If condition runs the
'     Then branch. So nothing that can fail is evaluated inside an If.
'  2. "On Error Resume Next" does not carry into functions. Without its own,
'     an error in a function aborts it and resurfaces in the caller. So every
'     function below enables it itself.
Function CanSkip()
    On Error Resume Next
    CanSkip = False
    Dim wmi, procs, n, os, boot, ts, text, v
    Err.Clear

    Set wmi = GetObject("winmgmts:\\.\root\cimv2")
    If Err.Number <> 0 Then Exit Function

    Set procs = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name = 'obs64.exe'")
    n = -1
    n = procs.Count
    If Err.Number <> 0 Then Exit Function
    If n < 1 Then Exit Function

    boot = ""
    For Each os In wmi.ExecQuery("SELECT LastBootUpTime FROM Win32_OperatingSystem")
        boot = os.LastBootUpTime
    Next
    If Err.Number <> 0 Then Exit Function
    If Len(boot) < 14 Then Exit Function

    Set ts = fso.OpenTextFile(stateFile, 1)   ' missing file -> error -> run
    If Err.Number <> 0 Then Exit Function
    text = ""
    text = ts.ReadAll                           ' empty file -> error 62 -> run
    ts.Close
    If Err.Number <> 0 Then Exit Function

    v = Field(text, "lastSeenBoot")
    If Err.Number <> 0 Then Exit Function
    If v <> boot Then Exit Function
    v = Field(text, "graceUntil")
    If Err.Number <> 0 Then Exit Function
    If v <> "" Then Exit Function
    v = Field(text, "snoozeUntil")
    If Err.Number <> 0 Then Exit Function
    If v <> "" Then Exit Function

    CanSkip = True
End Function

' Value of a "name": "value" string field, or "?" if it isn't there exactly
' once. "?" never equals a real value, so the gate falls through and runs.
Function Field(text, name)
    On Error Resume Next
    Dim re, m, c
    Field = "?"
    Set re = New RegExp
    re.Global = True        ' default False stops at the first match, hiding duplicates
    re.Pattern = """" & name & """\s*:\s*""([^""]*)"""
    Set m = re.Execute(text)
    c = 0
    c = m.Count
    If Err.Number <> 0 Then Exit Function
    If c = 1 Then Field = m(0).SubMatches(0)
    If Err.Number <> 0 Then Field = "?"
End Function

Sub RunWatchdog()
    On Error Resume Next
    Err.Clear
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """", 0, False
End Sub
````

### run-hidden.vbs

````vb
' Runs a PowerShell script with zero window flash.
' Usage: wscript.exe run-hidden.vbs <script.ps1> [args...]
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File"
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & " """ & WScript.Arguments(i) & """"
Next
sh.Run cmd, 0, False
````

### obs-replay-flush.lua

````lua
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
    if obs then
        -- Isolated so a keep-alive fault can never stop focus sampling.
        -- (M.K, not K: the local K is declared further down.)
        local ok, err = pcall(M.keepalive)
        if not ok and not M.K.warned then M.K.warned = true; print("keep-alive error: " .. tostring(err)) end
    end
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

-- ------------------------------------------------ replay buffer keep-alive ---
-- The buffer must always be running while OBS is open. This replaces the old
-- external obs-websocket check: it rides the existing 1 Hz sample timer, so it
-- costs one boolean call per second.
--
-- It stays hands-off when a stop is expected:
--   * first STARTUP_GRACE s after load (OBS starts the buffer itself via
--     --startreplaybuffer about 1 s after scripts load)
--   * during the post-save flush (stop -> STOPPED event -> start)
--   * once OBS is exiting
-- A failing start (e.g. encoder error) makes OBS show an error dialog, so
-- retries back off 10 s, 20 s, 40 s ... up to 5 min, and reset once the
-- buffer is seen running again.

local STARTUP_GRACE = 15
local FLUSH_HOLD = 5
local RETRY_MIN, RETRY_MAX = 10, 300

local K = { loaded_at = 0, hold_until = 0, next_try = 0, delay = RETRY_MIN, exiting = false }
M.K = K

local function buffer_available()
    local out = obs.obs_frontend_get_replay_buffer_output()
    if out == nil then return false end   -- replay buffer disabled in settings
    obs.obs_output_release(out)
    return true
end

function M.keepalive()
    local now = M.now()
    if K.exiting or now < K.loaded_at + STARTUP_GRACE then return end

    if obs.obs_frontend_replay_buffer_active() then
        K.delay, K.next_try = RETRY_MIN, 0
        return
    end
    if now < K.hold_until then return end
    -- The flush never saw its STOPPED event: drop the flag so a later
    -- manual stop isn't mistaken for a flush.
    restarting = false
    if now < K.next_try or not buffer_available() then return end

    print("keep-alive: replay buffer was off, starting it")
    obs.obs_frontend_replay_buffer_start()
    K.next_try = now + K.delay
    K.delay = math.min(K.delay * 2, RETRY_MAX)
end

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
        K.hold_until = M.now() + FLUSH_HOLD
        obs.timer_add(do_stop, 100)
    elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED and restarting then
        restarting = false
        K.hold_until = M.now() + FLUSH_HOLD   -- do_start fires in 500 ms
        obs.timer_add(do_start, 500)
    elseif event == obs.OBS_FRONTEND_EVENT_EXIT
        or event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
        K.exiting = true
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
    K.loaded_at = M.now()
    obs.timer_add(sample_tick, SAMPLE_MS)
    sample_tick()
    print("replay-flush + smart game-sort loaded")
end

function script_unload()
    obs.timer_remove(sample_tick)
end

function script_description()
    return "Flush the replay buffer after each save (no overlap), keep the replay buffer " ..
           "running while OBS is open, and sort clips/recordings into per-game folders " ..
           "using the app that held focus for most of the clip " ..
           "(ignores Discord/Steam/shell pass-throughs)."
end
````

### OBS-flow.mmd

````mermaid
---
config:
  theme: base
  themeVariables:
    fontFamily: Segoe UI, Arial
    fontSize: 15px
    primaryColor: "#eef4ff"
    primaryBorderColor: "#4a6fa5"
    lineColor: "#4a6fa5"
---
flowchart TD
    subgraph A ["1. EVERY MINUTE: Windows checks on OBS (Task Scheduler)"]
        direction TB
        T1["Task Scheduler<br/>at logon + every 1 min"] --> G{"obs-watchdog-gate.vbs<br/>OBS running AND nothing pending?"}
        G -->|"yes, about 99.9% of runs<br/>~30 ms CPU"| Q1["exit, nothing to do"]
        G -->|"no, or any error"| W["obs-replay-watchdog.ps1<br/>~280 ms CPU, only when needed"]
        W --> D1{"OBS running?"}
        D1 -->|yes| U["update state, remove old toast"]
        D1 -->|no| D2{"first run since boot?"}
        D2 -->|yes| L1["launch OBS silently"]
        D2 -->|no| D3{"Stay off pressed?"}
        D3 -->|"yes, under 5 min"| Q2["wait"]
        D3 -->|no| D4{"toast already shown?"}
        D4 -->|"no, OBS just closed"| TO["save 5 min timer, then show toast"]
        D4 -->|"yes, under 5 min"| Q3["wait"]
        D4 -->|"yes, 5 min passed"| L2["relaunch OBS"]
    end

    subgraph B ["2. TOAST BUTTONS"]
        direction TB
        TO -.-> BT1["Relaunch now"]
        TO -.-> BT2["Stay off 5 min"]
        TO -.-> BT3["X or ignore"]
        BT1 --> L3["launch OBS now"]
        BT2 --> SN["quiet for 5 min, then toast again"]
        BT3 -->|"after the 5 min timer"| L2
    end

    subgraph C ["3. EVERY LAUNCH"]
        direction TB
        L1 --> CL["delete leftover crash markers<br/>so no Safe Mode popup"]
        L2 --> CL
        L3 --> CL
        CL --> OB["obs64 --startreplaybuffer --minimize-to-tray"]
    end

    subgraph D ["4. INSIDE OBS: obs-replay-flush.lua, every 1 second"]
        direction TB
        OB --> TK["which window is in front?<br/>~0.008 microseconds"]
        TK --> KA{"replay buffer on?"}
        KA -->|yes| OK["nothing"]
        KA -->|"no, and not mid-save"| RS["start it again<br/>measured: back in 1.3 s"]
    end

    subgraph E ["5. ALT+Z SAVE"]
        direction TB
        SV["Alt+Z"] --> SC["folder = app in front<br/>longest during the clip"]
        SC --> MV["move to Videos\GameName\<br/>adds (2) if name taken"]
        MV --> FL["restart buffer once<br/>so next clip has no repeat"]
    end
    TK -.-> SC

    ST[("obs-watchdog-state.json<br/>boot, toast timer, snooze")]
    LG[("obs-watchdog.log<br/>one line per real action")]
    W -.-> ST
    W -.-> LG
````

### test-watchdog.ps1

````powershell
# Tests for the OBS watchdog. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-watchdog.ps1
# Covers every decision branch, plus the runner with fake OBS / toast / clock
# in a temp folder. Never touches the real state file, log, OBS, or toasts.
$ErrorActionPreference = 'Stop'
$tmp = Join-Path $env:TEMP ("obs-watchdog-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$env:OBS_WATCHDOG_STATEDIR = $tmp
. (Join-Path $PSScriptRoot 'obs-watchdog-common.ps1')

$script:pass = 0; $script:fail = 0
function Check($name, $got, $expect) {
    if ("$got" -eq "$expect") { $script:pass++; "PASS  $name" }
    else { $script:fail++; "FAIL  $name  expected=[$expect] got=[$got]" }
}

$BOOT  = '20260924085141.500000-240'
$BOOT2 = '20260925090000.000000-240'
$NOW   = [datetime]'2026-09-24T12:00:00'
function S($boot = $BOOT, $snooze = '', $grace = '') {
    $s = New-State; $s.lastSeenBoot = $boot; $s.snoozeUntil = $snooze; $s.graceUntil = $grace; $s
}
function D($state, $running, $now = $NOW) {
    Get-WatchdogDecision -State $state -Boot $BOOT -ObsRunning $running -Now $now
}
$later  = $NOW.AddMinutes(3).ToString('o')
$before = $NOW.AddMinutes(-1).ToString('o')

'--- decisions ---'
Check 'running, state current -> none'               (D (S) $true).Action 'none'
Check 'running, new boot -> running-update'          (D (S $BOOT2) $true).Action 'running-update'
Check 'running, toast pending -> clear toast'        (D (S $BOOT '' $later) $true).Action 'running-clear-toast'
Check 'running, snoozed -> update (snooze cleared)'  (D (S $BOOT $later '') $true).State.snoozeUntil ''
Check 'fresh state file, OBS off -> launch-boot'     (D (New-State) $false).Action 'launch-boot'
Check 'new boot, OBS off -> launch-boot'             (D (S $BOOT2) $false).Action 'launch-boot'
Check 'launch-boot records boot'                     (D (S $BOOT2) $false).State.lastSeenBoot $BOOT
Check 'just closed -> toast'                         (D (S) $false).Action 'toast'
Check 'toast sets grace to now+5min'                 (D (S) $false).State.graceUntil $NOW.AddMinutes(5).ToString('o')
Check 'grace pending -> wait-grace'                  (D (S $BOOT '' $later) $false).Action 'wait-grace'
Check 'grace expired -> relaunch-grace'              (D (S $BOOT '' $before) $false).Action 'relaunch-grace'
Check 'relaunch clears grace'                        (D (S $BOOT '' $before) $false).State.graceUntil ''
Check 'snoozed -> wait-snooze'                       (D (S $BOOT $later '') $false).Action 'wait-snooze'
Check 'snooze over -> toast again'                   (D (S $BOOT $before '') $false).Action 'toast'
Check 'garbage timer -> toast (self-heals)'          (D (S $BOOT 'not-a-date' 'junk') $false).Action 'toast'
Check 'decision does not mutate input'               ($(
        $in = S $BOOT '' $later; $null = D $in $true; $in.graceUntil)) $later

'--- legacy boot format migration ---'
$legacy = S '2026-09-24T08:51:41.5000000-04:00'
Check 'old ISO boot of SAME boot is migrated'        (Update-LegacyBoot $legacy $BOOT).lastSeenBoot $BOOT
Check 'migrated + OBS off -> toast, not relaunch'    (D (Update-LegacyBoot (S '2026-09-24T08:51:41.5000000-04:00') $BOOT) $false).Action 'toast'
Check 'old ISO boot of OTHER boot is left alone'     (Update-LegacyBoot (S '2026-09-20T10:00:00.0000000-04:00') $BOOT).lastSeenBoot '2026-09-20T10:00:00.0000000-04:00'

'--- runner with fakes (temp dir) ---'
$script:obsUp = $false; $script:launches = 0; $script:toasts = 0; $script:clock = $NOW
$script:toastThrows = $false
function Get-Now { $script:clock }
function Get-BootId { $BOOT }
function Test-ObsRunning { $script:obsUp }
function Start-Obs { $script:launches++; $script:obsUp = $true }
function Show-Toast { if ($script:toastThrows) { throw 'toast subsystem broken' }; $script:toasts++ }
function Remove-Toast { }

Save-State (S)
Invoke-Watchdog
Check 'closed: one toast'                            $script:toasts 1
Check 'closed: grace persisted'                      ([bool](Read-State).graceUntil) $true
$script:clock = $NOW.AddMinutes(2); Invoke-Watchdog
Check 'inside grace: no second toast, no launch'     "$($script:toasts)/$($script:launches)" '1/0'
$script:clock = $NOW.AddMinutes(6); Invoke-Watchdog
Check 'grace expired: relaunched once'               $script:launches 1

# The bug this rewrite fixes: a failing toast used to stop the script before
# graceUntil was saved, so OBS was never relaunched.
$script:obsUp = $false; $script:launches = 0; $script:toastThrows = $true; $script:clock = $NOW
Save-State (S)
Invoke-Watchdog
Check 'toast throws: grace STILL persisted'          ([bool](Read-State).graceUntil) $true
Check 'toast throws: failure logged'                 ([bool](Select-String -Path $LogFile -Pattern 'TOAST FAILED' -Quiet)) $true
$script:clock = $NOW.AddMinutes(6); Invoke-Watchdog
Check 'toast throws: still auto-relaunches'          $script:launches 1
$script:toastThrows = $false

'--- buttons ---'
$script:obsUp = $false; $script:launches = 0; $script:clock = $NOW
Save-State (S $BOOT '' $later)
Invoke-ToastAction 'obs-watchdog:snooze'
Check 'snooze: snoozeUntil = now+5'                  (Read-State).snoozeUntil $NOW.AddMinutes(5).ToString('o')
Check 'snooze: grace cleared'                        (Read-State).graceUntil ''
Invoke-Watchdog
Check 'snoozed: watchdog stays quiet'                "$($script:launches)" '0'
Invoke-ToastAction 'obs-watchdog:relaunch'
Check 'relaunch button: launched'                    $script:launches 1
Invoke-ToastAction 'obs-watchdog:relaunch'
Check 'relaunch button twice: no second OBS'         $script:launches 1

'--- state file robustness ---'
Set-Content $StateFile '{ this is not json'
Check 'corrupt state file -> fresh state'            (Read-State).lastSeenBoot ''
Save-State (S)
Check 'atomic save leaves no temp file'              (Test-Path "$StateFile.tmp") $false
Check 'saved file round-trips'                       (Read-State).lastSeenBoot $BOOT

'--- crash marker cleanup (Safe Mode prompt) ---'
$sd = Join-Path $tmp 'sentinel'
New-Item -ItemType Directory $sd | Out-Null
$SentinelDir = $sd
'x' | Set-Content (Join-Path $sd 'run_aaaa')
'x' | Set-Content (Join-Path $sd 'run_bbbb')
'x' | Set-Content (Join-Path $sd 'keep_me.txt')
Check 'clears both stale run_* markers'              (Clear-ObsCrashFlag) 2
Check 'no run_* markers left'                        @(Get-ChildItem $sd -Filter 'run_*').Count 0
Check 'unrelated files untouched'                    (Test-Path (Join-Path $sd 'keep_me.txt')) $true
Check 'nothing to clear -> 0'                        (Clear-ObsCrashFlag) 0
$SentinelDir = Join-Path $tmp 'does-not-exist'
Check 'missing sentinel dir -> 0, no error'          (Clear-ObsCrashFlag) 0

'--- quiet runs write nothing ---'
Remove-Item $LogFile -ErrorAction SilentlyContinue
$script:obsUp = $true; Save-State (S)
1..5 | ForEach-Object { Invoke-Watchdog }
Check 'steady state: no log lines'                   (Test-Path $LogFile) $false

'--- legacy state is migrated and SAVED even when nothing else happens ---'
$script:obsUp = $true
Save-State (S '2026-09-24T08:51:41.5000000-04:00')
Invoke-Watchdog
Check 'legacy boot persisted in new format'          (Read-State).lastSeenBoot $BOOT
Remove-Item $LogFile -ErrorAction SilentlyContinue
Invoke-Watchdog
Check 'after migration: quiet again'                 (Test-Path $LogFile) $false

Remove-Item $tmp -Recurse -Force
Remove-Item Env:\OBS_WATCHDOG_STATEDIR
"`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
````

### test-gate.ps1

````powershell
# Tests for obs-watchdog-gate.vbs. Run:
#   powershell -NoProfile -ExecutionPolicy Bypass -File test-gate.ps1
# Uses the gate's test hook: OBS_WATCHDOG_STATEDIR points it at a temp state
# file, and it exits 10 (skip) or 20 (would run the watchdog) instead of
# launching anything. Real obs64 presence and real boot time are used, so run
# this while OBS is open.
$ErrorActionPreference = 'Stop'
$gate = Join-Path $PSScriptRoot 'obs-watchdog-gate.vbs'
$tmp  = Join-Path $env:TEMP ("obs-gate-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
$state = Join-Path $tmp 'obs-watchdog-state.json'
$boot  = [string](Get-WmiObject Win32_OperatingSystem).LastBootUpTime
$obsUp = [bool](Get-Process obs64 -ErrorAction SilentlyContinue)
if (-not $obsUp) { 'OBS is not running: start it first (the skip cases need it).'; exit 2 }

$script:pass = 0; $script:fail = 0
function Gate {
    $env:OBS_WATCHDOG_STATEDIR = $tmp
    $p = Start-Process wscript.exe -ArgumentList "`"$gate`"" -Wait -PassThru
    Remove-Item Env:\OBS_WATCHDOG_STATEDIR
    switch ($p.ExitCode) { 10 { 'skip' } 20 { 'run' } default { "exit$($p.ExitCode)" } }
}
function Case($name, $content, $expect) {
    Remove-Item $state -Recurse -Force -ErrorAction SilentlyContinue
    if ($content -eq 'DIR') { New-Item -ItemType Directory $state | Out-Null }
    elseif ($content -eq 'SAVESTATE') {
        # Write it exactly the way the watchdog does, to prove the two agree.
        $env:OBS_WATCHDOG_STATEDIR = $tmp
        powershell -NoProfile -Command ". '$PSScriptRoot\obs-watchdog-common.ps1'; `$s = New-State; `$s.lastSeenBoot = '$boot'; Save-State `$s"
        Remove-Item Env:\OBS_WATCHDOG_STATEDIR
    }
    elseif ($null -ne $content) { [IO.File]::WriteAllText($state, $content) }
    $got = Gate
    if ($got -eq $expect) { $script:pass++; "PASS  $name -> $got" }
    else { $script:fail++; "FAIL  $name  expected=$expect got=$got" }
}
function J($b, $s, $g) { @{ lastSeenBoot = $b; snoozeUntil = $s; graceUntil = $g } | ConvertTo-Json }

Case 'steady state (OBS up, boot handled, no timers)' (J $boot '' '')                 'skip'
Case 'toast pending'                                  (J $boot '' '2099-01-01T00:00:00') 'run'
Case 'snoozed'                                        (J $boot '2099-01-01T00:00:00' '') 'run'
Case 'different boot'                                 (J '20200101000000.000000-240' '' '') 'run'
Case 'legacy ISO boot format'                         (J '2026-09-24T08:51:41.5000000-04:00' '' '') 'run'
Case 'no state file'                                  $null                             'run'
Case 'corrupt state file'                             '{ garbage'                       'run'
Case 'empty state file'                               ''                                'run'
Case 'field missing'                                  (@{ lastSeenBoot = $boot } | ConvertTo-Json) 'run'
Case 'compact JSON (no spaces) still parsed'          ('{"lastSeenBoot":"' + $boot + '","snoozeUntil":"","graceUntil":""}') 'skip'
Case 'state file is a folder (unreadable)'            'DIR'                             'run'
Case 'duplicate field'                                ('{"lastSeenBoot":"' + $boot + '","lastSeenBoot":"' + $boot + '","snoozeUntil":"","graceUntil":""}') 'run'
Case 'real state file written by Save-State'          'SAVESTATE'                       'skip'

Remove-Item $tmp -Recurse -Force
"`n$($script:pass) passed, $($script:fail) failed"
if ($script:fail) { exit 1 }
````

### test-obs-sort.lua

````lua
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
````

### test-obs-win32.lua

````lua
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
    obs_frontend_replay_buffer_active = function() return true end,
    obs_frontend_get_replay_buffer_output = function() return nil end,   -- forces the default length
    obs_frontend_get_last_replay = function() return "C:\\Users\\someone\\Videos\\clip.mp4" end,
    obs_frontend_get_last_recording = function() return "C:\\Users\\someone\\Videos\\rec.mp4" end,
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
````

### test-obs-collision.lua

````lua
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
````

### test-obs-keepalive.lua

````lua
-- Tests for the replay-buffer keep-alive in obs-replay-flush.lua.
-- Run: lua test-obs-keepalive.lua   (plain Lua; the win32 layer is stubbed)
-- Drives a fake OBS with a virtual clock and asserts exactly when the script
-- starts the buffer, and when it must keep its hands off.

local clock = 1000000
local active = true           -- is the replay buffer running?
local available = true        -- is the replay buffer enabled in settings?
local starts, stops = 0, 0
local timers = {}

obslua = {
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED = 1,
    OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED = 2,
    OBS_FRONTEND_EVENT_RECORDING_STARTED = 3,
    OBS_FRONTEND_EVENT_RECORDING_STOPPED = 4,
    OBS_FRONTEND_EVENT_EXIT = 5,
    OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN = 6,
    obs_frontend_add_event_callback = function() end,
    timer_add = function(f, ms) timers[f] = ms end,
    timer_remove = function(f) timers[f] = nil end,
    obs_frontend_replay_buffer_active = function() return active end,
    obs_frontend_replay_buffer_start = function() starts = starts + 1; active = true end,
    obs_frontend_replay_buffer_stop = function() stops = stops + 1; active = false end,
    obs_frontend_get_replay_buffer_output = function() if available then return {} end return nil end,
    obs_output_release = function() end,
    obs_output_get_settings = function() return nil end,
    obs_frontend_get_last_replay = function() return nil end,
    obs_frontend_get_last_recording = function() return nil end,
}
-- The script only loads its ffi layer when `obslua` is present; stub the one
-- ffi-backed call the tick needs so this runs under plain Lua.
package.loaded.ffi = {
    cdef = function() end,
    load = function() return {} end,
    new = function() return {} end,
    string = function() return "" end,
}

local dir = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
assert(loadfile(dir .. "/obs-replay-flush.lua"))()
local M = OBS_CLIP_SORT
M.now = function() return clock end
M.foreground_info = function() return "FortniteClient-Win64-Shipping", 2.0 end
M.move_to_folder = function() end
local K = M.K

local pass, fail = 0, 0
local function check(name, got, expect)
    if got == expect then pass = pass + 1; print("PASS  " .. name)
    else fail = fail + 1; print("FAIL  " .. name .. "  expected=" .. tostring(expect) .. " got=" .. tostring(got)) end
end
local function tick(n) for _ = 1, n or 1 do clock = clock + 1; sample_tick() end end
local function fresh()
    K.exiting, K.hold_until, K.next_try, K.delay, K.warned = false, 0, 0, 10, nil
    active, available, starts, stops = true, true, 0, 0
    script_load(nil)   -- sets loaded_at = now
end

-- 1) Startup grace: OBS itself starts the buffer ~1 s after load. Don't race it.
fresh(); active = false
tick(14)
check("no start during 15 s startup grace", starts, 0)
tick(2)
check("starts once grace is over", starts, 1)

-- 2) Buffer already running: never touched.
fresh(); tick(120)
check("running buffer is left alone", starts, 0)

-- 3) Manual stop while OBS is open: back within ~1 s after grace.
fresh(); tick(20)
active = false; tick(1)
check("manual stop -> restarted next tick", starts, 1)
check("buffer is active again", active, true)

-- 4) Save flush: stop -> STOPPED -> start is the script's own job. Keep-alive
--    must not add a second start in between.
fresh(); tick(20)
on_event(obslua.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED)
active = false                                   -- do_stop ran
on_event(obslua.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED)
tick(1)                                          -- do_start not fired yet
check("no keep-alive start during flush", starts, 0)
do_start()                                       -- the 500 ms timer fires
check("flush restart happens exactly once", starts, 1)
tick(10)
check("still exactly one start after flush", starts, 1)

-- 5) Flush whose STOPPED event never arrives: recovers after the hold.
fresh(); tick(20)
on_event(obslua.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED)
active = false                                   -- stopped, but no event
tick(4)
check("held during flush window", starts, 0)
tick(2)
check("stuck flush recovered after hold", starts, 1)

-- 6) OBS exiting: never restart what shutdown stopped.
fresh(); tick(20)
on_event(obslua.OBS_FRONTEND_EVENT_EXIT)
active = false; tick(30)
check("no restart while OBS is exiting", starts, 0)

-- 7) Replay buffer disabled in settings: don't hammer a missing output.
fresh(); tick(20)
available, active = false, false; tick(30)
check("no start when replay buffer is disabled", starts, 0)

-- 8) Start keeps failing: back off 10, 20, 40 s instead of every second.
fresh(); tick(20)
obslua.obs_frontend_replay_buffer_start = function() starts = starts + 1 end  -- stays off
active = false
tick(1);  check("first retry immediate", starts, 1)
tick(9);  check("no retry before 10 s", starts, 1)
tick(1);  check("second retry at 10 s", starts, 2)
tick(19); check("no retry before +20 s", starts, 2)
tick(1);  check("third retry at +20 s", starts, 3)
obslua.obs_frontend_replay_buffer_start = function() starts = starts + 1; active = true end
tick(40); check("start succeeds on the next scheduled retry", active, true)
tick(1);  check("backoff resets once running is observed", K.delay, 10)

-- 9) A fault inside keep-alive must not break focus sampling.
fresh(); tick(20)
local saved = obslua.obs_frontend_replay_buffer_active
obslua.obs_frontend_replay_buffer_active = function() error("boom") end
M.spans = {}
local ok = pcall(tick, 5)
check("tick survives keep-alive error", ok, true)
check("focus still recorded", #M.spans > 0, true)
obslua.obs_frontend_replay_buffer_active = saved

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
````
