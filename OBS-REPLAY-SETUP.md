# OBS Always-On Replay Buffer + Auto Clip Sorting

> **SUPERSEDED 2026-09-24.** Parts of this file describe the OLD design (websocket buffer check, `run-hidden.vbs` as the task action, `--disable-shutdown-check`). The current, tested setup is in **OBS-REBUILD-FROM-SCRATCH.md** (flow chart: `OBS-flow.png` / `OBS-flow.mmd`). Kept for history only.

Reconstructed spec of the setup originally built **2026-07-04** (that conversation is gone: it predates jcode, whose history starts 2026-07-26, and the Claude Code transcript was purged). Everything below was read directly off this machine on 2026-09-24.

Goal: the replay buffer is **always running** so a clip is never missed, and saved clips auto-file into `Videos\<game>\`.

---

## 1. Components

| File / object | Role |
|---|---|
| `C:\Users\blare\Scripts\obs-replay-watchdog.ps1` | Main watchdog. Launches OBS, or ensures the replay buffer is on via obs-websocket. |
| `C:\Users\blare\Scripts\obs-watchdog-action.ps1` | Handles toast button clicks (`obs-watchdog:` protocol). |
| `C:\Users\blare\Scripts\obs-watchdog-state.json` | Persisted state: `lastSeenBoot`, `snoozeUntil`, `graceUntil`. |
| `C:\Users\blare\Scripts\run-hidden.vbs` | Generic "run a .ps1 with zero window flash" shim (`sh.Run cmd, 0, False`). |
| `C:\Users\blare\Scripts\obs-replay-flush.lua` | OBS script: flushes the buffer after each save, sorts clips per game. |
| `C:\Users\blare\Scripts\test-obs-sort.lua`, `test-obs-win32.lua` | Test harness for the pure scoring half, runs under plain Lua with no OBS. |
| Scheduled task `\OBS Replay Buffer Watchdog` | Runs the watchdog. |
| `HKCR\obs-watchdog` | URL protocol backing the toast buttons. |
| OBS profile `GameRec-AV1` (**live dir is `GameRecAV1`**) | Recording / replay-buffer settings. |
| `basic\profiles\GameRec-AV1\` | **Stale leftover dir** from 2026-07-04, contains only an old `recordEncoder.json`. OBS does not read it. Ignore it. |

---

## 2. Scheduled task

Name: `\OBS Replay Buffer Watchdog`

```
Action:   wscript.exe "C:\Users\blare\Scripts\run-hidden.vbs" "C:\Users\blare\Scripts\obs-replay-watchdog.ps1"
Triggers: LogonTrigger (blare), 30s delay
          TimeTrigger from 2026-07-04, repeat every 1 minute for 3650 days
Principal: blare, InteractiveToken (NOT highest privileges - needed so toasts show)
Settings:  ExecutionTimeLimit PT3M, MultipleInstancesPolicy IgnoreNew,
           StartWhenAvailable true, battery restrictions disabled
```

InteractiveToken matters: the toast and the OBS window must live in the user session.

## 3. Protocol handler

```
HKCR\obs-watchdog
  (Default)    = "URL:OBS Watchdog Protocol"
  URL Protocol = ""
  shell\open\command =
    wscript.exe "C:\Users\blare\Scripts\run-hidden.vbs" "C:\Users\blare\Scripts\obs-watchdog-action.ps1" "%1"
```

URIs: `obs-watchdog:relaunch`, `obs-watchdog:snooze`.

---

## 4. Watchdog logic (runs once a minute)

Launch command used everywhere:

```
obs64.exe --startreplaybuffer --minimize-to-tray --disable-shutdown-check
  (cwd C:\Program Files\obs-studio\bin\64bit)
```

**If OBS is not running:**

1. `lastSeenBoot != current boot time` -> **first launch this boot: start OBS silently, no prompt.** Record boot time, clear timers.
2. Inside `snoozeUntil` -> do nothing (user explicitly said stay off).
3. `graceUntil` set:
   - still within it -> do nothing, toast is pending.
   - expired -> **relaunch anyway** (recording is never silently forgotten), clear toast.
4. Otherwise OBS was just closed -> show toast, set `graceUntil = now + 5 min`.

Toast: "OBS closed - replay buffer is OFF", buttons **Relaunch now** / **Stay off 5 min**, scenario `reminder`, tag/group `obs-watchdog`, AppID is the PowerShell shell ID `{1AC14E77-...}\WindowsPowerShell\v1.0\powershell.exe`.

**If OBS is running:** clear stale snooze/grace/toast, then over **obs-websocket v5 on `ws://127.0.0.1:4455`**:

- password read from `%APPDATA%\obs-studio\plugin_config\obs-websocket\config.json` -> `server_password`
- auth: `sha256b64( sha256b64(password + salt) + challenge )`
- `GetReplayBufferStatus`; if `outputActive` is false -> `StartReplayBuffer`
- 10 s CancellationTokenSource; any failure (OBS still booting, server off) exits 0 and retries next minute.

The design rule throughout: **never lose a recording to an unanswered prompt**, but always give a 5 minute window to say no.

---

## 5. OBS Lua script (`obs-replay-flush.lua`)

Loaded via **Tools -> Scripts**. Prints `replay-flush + smart game-sort loaded`. Reload after editing (refresh button in the script list, no OBS restart needed).

Two jobs:

1. **Flush.** On `REPLAY_BUFFER_SAVED`: stop the buffer after 100 ms, restart 500 ms after `REPLAY_BUFFER_STOPPED`, so consecutive clips never share overlapping footage.
2. **Sort.** Move the saved file into `Videos\<game>\`.

Folder choice is not a single snapshot of the foreground window. A **1 Hz sampler** records focus over time; at save time only samples inside the clip's own time window are scored.

- History is run-length encoded as spans `{exe, w, t0, t1}`, so an hour in one game is one table entry.
- Weights: fullscreen 2.0, windowed 1.0 (fullscreen re-measured every sample since a game can toggle without changing HWND).
- Tiers: `content` wins; `overlay` (Discord, Steam, OBS, Spotify, Epic, taskmgr...) only if nothing else was focused; `desktop` (explorer, dwm, search...) never wins, falls back to `Desktop`.
- Clip window length comes from the live replay buffer `max_time_sec`, default 120 s. Recordings use actual start-to-stop span.
- Retention 1 hour, samples more than 5 s apart break a span.

Consequences: start on desktop then launch a game -> game folder. Alt-tab to Discord then hit save -> still the game folder.

**Cost.** Runs inside OBS's video tick (Lua timers are driven by `obs_add_tick_callback`, the render thread), so it must stay tiny, and it does. Full probe ~33 us, but the PID->exe lookup is cached per HWND, so a steady-state sample is ~0.008 us. At 1 Hz that is ~0.000001% of one core. Buffers are preallocated so sampling never allocates.

The scoring half is pure and exported as `OBS_CLIP_SORT` for the offline test harness.

---

## 6. OBS profile `GameRec-AV1`

Active profile: `user.ini -> Profile=GameRec-AV1`, **`ProfileDir=GameRecAV1`**. Scene collection `Untitled`.

Trap: there are two similarly named directories under `basic\profiles\`. Only `GameRecAV1` is live (its `basic.ini` is rewritten by OBS on every launch). `GameRec-AV1` is an orphan from the original July 4 build and holds a stale encoder file. Edit the wrong one and nothing happens.

```
Output mode:      Advanced
Video:            2560x1440 base and output, 60 fps, lanczos, NV12 / 709 / Partial
Record encoder:   obs_nvenc_av1_tex  (NVENC AV1)
Encoder settings: CQP 20, preset2 p7 (+ legacy "preset":"p5" key), tune hq,
                  multipass disabled, profile main, keyint 2 s, bf 2,
                  lookahead off, AQ on
                  (from GameRecAV1\recordEncoder.json, last changed 2026-09-22)
Container:        hybrid_mp4
Path:             C:\Users\blare\Videos
Replay buffer:    RecRB=true, RecRBTime=600 (10 min), RecRBSize=4096 MB, prefix "rb"
Audio:            ffmpeg_aac, 48 kHz stereo, 3 record tracks
Save hotkey:      Alt+Z  (ReplayBuffer.Save)
```

Note `RecSplitFileTime=15` / `RecSplitFileType=Time` applies to normal recordings, not the buffer.

---

## 7. Verified live state (2026-09-24)

Every item below was observed, not inferred:

- Task state `Ready`, `LastTaskResult 0`, last run 10:24, next run 10:25 -> the 1-minute loop is healthy.
- `obs64` PID 2384, started 08:58, about 7 min after the 08:51 boot -> the logon-trigger silent launch path works.
- `obs-watchdog-state.json` `lastSeenBoot` exactly matches `Win32_OperatingSystem.LastBootUpTime`, snooze and grace both empty -> normal steady state.
- obs-websocket config: `server_enabled true`, `auth_required true`, `server_port 4455` -> matches what the watchdog assumes.
- Scene collection `Untitled.json` loads exactly one script: `C:/Users/blare/Scripts/obs-replay-flush.lua`.
- Sorting demonstrably works: `Videos\FortniteClient-Win64-Shipping\` holds recent clips (`rb Sep 23 10.08 PM.mp4`), while only one stray `rb Sep 21 09.14 PM.mp4` sits unsorted in `Videos\` root.
- Folders are named by **executable**, so Fortnite lands in `FortniteClient-Win64-Shipping`, not a pretty title. `Videos\Captures` is an empty Windows default, unrelated.
- Some clips carry a `_trim_198-599` suffix, from the separate `mp4trim` project, not from this setup.

---

## 8. Known trade-off

The buffer runs **24/7**, which a Sep 2026 optimization pass flagged as the top A/B candidate for Fortnite 1% lows (it holds an NVENC session open permanently). Decision at the time: **keep it**, clipping is worth more than the margin. If chasing frames, toggle the scheduled task off and A/B it rather than deleting anything.

---

## 9. Operations cheat sheet

```powershell
# is it alive
Get-ScheduledTask "OBS Replay Buffer Watchdog"
Get-Process obs64

# force a check now
Start-ScheduledTask "OBS Replay Buffer Watchdog"

# disable / re-enable (A/B testing)
Disable-ScheduledTask "OBS Replay Buffer Watchdog"
Enable-ScheduledTask  "OBS Replay Buffer Watchdog"

# state
Get-Content C:\Users\blare\Scripts\obs-watchdog-state.json

# full task definition
schtasks /query /tn "OBS Replay Buffer Watchdog" /xml ONE
```

Reload the Lua after editing: OBS -> Tools -> Scripts -> `obs-replay-flush.lua` -> refresh.

---

## 10. History

- 2026-07-04 - built: watchdog, action handler, protocol, task, Lua flush script.
- 2026-08-05/06 - Lua rewritten from single-snapshot focus to the 1 Hz weighted sampler with RLE spans and the pure test harness (jcode session `fish`, `session_fish_1785979654114_792b3c6649dbb3c3`).
- 2026-09-13 - setup reconstructed from disk after the original transcript was lost; a bug was found and fixed (Claude Code session `e629dab1`).
- 2026-09-22 - read-only audit during the Fortnite optimization swarm (jcode session `lobster`, `session_lobster_1790116066588_e51eae6c58496e6a`).
- 2026-09-24 - this document written so the setup is never only-in-a-transcript again.
- 2026-09-24 - redesign: VBS gate, Lua keep-alive, crash-marker cleanup, no websocket (jcode session `orangutan`, `session_orangutan_1790259638502_5aa40afdf29546a7`).
- 2026-10-17 - **fix: NVENC not ready at boot.** After a bluescreen reboot (BugCheck 0x3B), OBS launched while the NVIDIA driver was still settling. OBS logged `[NVENC] Test process failed` / `NVENC not supported` / `Encoder ID 'obs_nvenc_av1_tex' not found`, so the replay buffer could never start. The Lua keep-alive retried forever, but only a fresh OBS process re-checks NVENC. Fixes:
  - `Start-Obs` runs `obs-nvenc-test.exe` (the same check OBS does) and waits up to 60 s for `nvenc_supported=true` before launching.
  - After 3 failed buffer starts, the Lua writes `Scripts\obs-restart-request`. The gate sees it, and the watchdog restarts OBS (at most 2x per boot). If that still doesn't help, it shows a "replay buffer is NOT running" toast instead of looping.
  - Log lines to look for: `waited N s for NVENC`, `replay buffer could not start (...): restarted OBS (1/2 this boot)`, `gave up, notified user`.
