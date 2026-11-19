# obs-replay-buffer

[![fresh-pc](https://github.com/blarer/obs-replay-buffer/actions/workflows/fresh-pc.yml/badge.svg)](https://github.com/blarer/obs-replay-buffer/actions/workflows/fresh-pc.yml)

Always-on OBS replay buffer for Windows. Press one key in any game and the last
N seconds land in `Videos\<game>\`, sorted by the game that was actually on
screen. OBS is kept open and the buffer kept running, through reboots and
crashes, by a tiny watchdog that costs about 30 ms of CPU per minute.

Works on any Windows 10/11 PC with OBS Studio 28 or newer. No admin rights, no
extra downloads, no OBS plugins.

The badge above is a real end-to-end install on a brand-new Windows machine
(GitHub's `windows-latest` runner, no GPU, nothing pre-installed): every push
installs OBS from the official release, runs `setup.ps1`, launches OBS, saves
a replay from inside OBS, checks that it was sorted into a subfolder, runs all
test suites, and uninstalls cleanly.

## What you get

| Piece | What it does |
|---|---|
| `obs-replay-flush.lua` | Runs inside OBS. After every save it restarts the buffer (so clips never overlap), moves the clip into `Videos\<game>\`, and restarts the buffer if OBS ever drops it. The folder is chosen by sampling which app had focus during the clip, so alt-tabbing to Discord before you press the key does not matter. |
| `obs-replay-watchdog.ps1` + `obs-watchdog-gate.vbs` | Scheduled task, once a minute. First run after boot launches OBS minimized with the buffer on. If you close OBS it shows a toast with **Relaunch now** / **Stay off 5 min**, and relaunches anyway after 5 minutes of no answer. If the Lua script reports the buffer cannot start (NVENC not ready after boot, etc.) it restarts OBS, up to twice per boot. |
| `setup.ps1` | Installs all of the above in one go. Also `-Status` and `-Uninstall`. |
| `tools/sort_clips.py` | Optional. Re-sorts clips that were already filed under the wrong folder by looking at the video content. Needs Python + ffmpeg. |

## Install (5 minutes)

1. Install [OBS Studio](https://obsproject.com). Start it once, finish the
   first-run wizard (pick "Optimize just for recording"), then close it.
2. Get this repo. Either `git clone https://github.com/blarer/obs-replay-buffer`
   or download the ZIP and extract it. Put the folder somewhere permanent
   (for example `C:\Users\<you>\obs-replay-buffer`), because everything runs
   from inside it. Moving the folder later means re-running setup.
3. Double-click **`setup.cmd`** (or from a terminal:
   `powershell -ExecutionPolicy Bypass -File setup.ps1`).

That's it. setup will:

- find your OBS install (regular, Steam, or pass `-ObsExe` for a portable one),
- turn on the replay buffer in every OBS profile and set **Alt+Z** as the save
  key if you don't already have one (existing hotkeys are kept),
- register `obs-replay-flush.lua` in your OBS scene collection,
- register the toast-button handler (per-user, HKCU only),
- register the scheduled task **OBS Replay Buffer Watchdog** running as you,
- start OBS minimized to the tray,
- print a status report so you can see every piece is green.

Then go play something and press Alt+Z. Look in `Videos\<GameName>\`.

### Check it later

```
powershell -ExecutionPolicy Bypass -File setup.ps1 -Status
```

Prints the OBS path, whether the script is registered and loaded, the state of
each profile, the scheduled task's last result, and the last watchdog log lines.

### Uninstall

Double-click **`uninstall.cmd`**. Removes the scheduled task, the protocol
handler and the script entry from OBS. Your OBS settings and clips are left
alone.

## How the sorting decides the folder

The Lua script samples the foreground window once a second (cached per window
handle, so the steady-state cost is a pointer compare). When you save, it
scores only the samples inside the clip's own time window:

- real apps (games, Blender, whatever) win by weighted focus time,
- fullscreen windows count double,
- Discord, Steam, Spotify, OBS, Task Manager and similar are "pass-through":
  they only decide the folder if nothing else was focused,
- Explorer, Start menu and other shell surfaces fall back to `Desktop`.

So "desktop, launch Fortnite, play, tab to Discord, press Alt+Z" lands in
`FortniteClient-Win64-Shipping\`. Edit `DESKTOP_APPS` / `OVERLAY_APPS` at the
top of `obs-replay-flush.lua` if an app is in the wrong tier, then reload the
script in OBS (Tools > Scripts > reload icon).

## Tuning

Everything lives in OBS's own settings, so change them the normal way
(Settings > Output > Replay Buffer: length and size; Settings > Hotkeys:
"Save Replay"). The script reads the buffer length from OBS at save time.

The watchdog's grace and snooze windows (5 min each) and the per-boot restart
cap (2) are at the top of `obs-watchdog-common.ps1`.

## Running without an NVIDIA GPU

Fine. The only NVIDIA-specific bit is a wait-for-NVENC check before launching
OBS after boot; it is skipped automatically when no NVIDIA adapter is present.
Use whatever encoder OBS offers you (AMD, Intel QSV, x264).

## Tests

```
run-tests.cmd
```

Seven suites, ~170 checks, none touch your real OBS config. The PowerShell
suites run anywhere. The Lua suites need `lua` and `luajit` on PATH
(`scoop install lua luajit`, or any Lua 5.x + LuaJIT builds); they are skipped
if missing. `tests\test-gate.ps1` needs OBS to be running.

## Troubleshooting

- **Clips go to `Videos\` root, not a subfolder.** The script isn't loaded.
  Run `setup.ps1 -Status`; if it says the OBS log doesn't show the script,
  open OBS > Tools > Scripts and check for an error under
  `obs-replay-flush.lua`.
- **The "OBS closed" toast has no buttons / buttons do nothing.** The
  protocol handler is missing. Re-run setup.
- **OBS opens a "Safe Mode?" dialog after a crash.** The watchdog clears the
  crash marker before relaunching, so this only happens if you start OBS by
  hand. Pick "Run normally".
- **Replay buffer keeps failing to start after boot.** The script asks the
  watchdog to restart OBS after 3 failed starts (max 2 restarts per boot),
  then shows a notice. Check `obs-watchdog.log` next to the scripts and OBS's
  own log for the encoder error.
- **I use a portable OBS.** `setup.ps1 -ObsExe "D:\obs\bin\64bit\obs64.exe"`.
  Portable OBS keeps its config in its own folder rather than
  `%APPDATA%\obs-studio`; setup does not edit that, so turn the replay buffer
  on and add the script in OBS's UI yourself.

## Repo layout

```
setup.ps1 / setup.cmd / uninstall.cmd   installer
obs-replay-flush.lua                     the OBS script
obs-replay-watchdog.ps1                  watchdog entry (Task Scheduler -> gate.vbs -> this)
obs-watchdog-common.ps1                  all watchdog logic (pure decision function + runners)
obs-watchdog-gate.vbs                    25 ms pre-check so PowerShell only starts when needed
obs-watchdog-action.ps1 / run-hidden.vbs toast button handler
obs-watchdog-task.template.xml           scheduled task, filled in by setup
run-tests.cmd / tests/                   test suites
tools/                                   optional after-the-fact visual clip sorter
docs/                                    design notes, flow chart, history
```

## Docs

- [docs/OBS-REPLAY-SETUP.md](docs/OBS-REPLAY-SETUP.md): how the pieces fit, decision table, log formats.
- [docs/OBS-FLOW-AND-SIMPLIFY.md](docs/OBS-FLOW-AND-SIMPLIFY.md): flow chart and the cost measurements behind the design.
- [docs/CLIP-SORTING-DETECTION.md](docs/CLIP-SORTING-DETECTION.md): the live focus sorter and the offline visual classifier.
- [docs/OBS-REBUILD-FROM-SCRATCH.md](docs/OBS-REBUILD-FROM-SCRATCH.md): the original hand-rebuild guide, superseded by `setup.ps1` but kept for the reasoning.

## License

MIT. See [LICENSE](LICENSE).
