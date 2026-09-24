# How clips get detected and sorted into folders

Companion to `OBS-REPLAY-SETUP.md`. This covers only one question: **how does a clip end up in `Videos\<something>\`, and how was that designed.**

There are **two independent systems**:

| | System A: live sorter | System B: after-the-fact classifier |
|---|---|---|
| File | `Scripts\obs-replay-flush.lua` | `Scripts\sort_clips.py` (+ helper scripts) |
| Runs | Inside OBS, automatically, on every save | By hand, only when you ask |
| Looks at | Which **window had focus** while the clip was being recorded | The **actual pixels** inside the video file |
| Purpose | Put new clips in the right folder | Fix clips that were filed wrong before System A was fixed |
| Built | 2026-07-04, rewritten 2026-08-05 | 2026-08-05 |

---

## System A: live focus-based sorter (the one that runs every day)

### Where files land

- OBS saves replays into `C:\Users\blare\Videos\` as `rb <Mon> <DD> <HH>.<MM> <AM/PM>.mp4`. The `rb` prefix comes from `RecRBPrefix`, the rest from `FilenameFormatting=%b %d %I.%M %p`.
- The Lua script then **moves** the file to `Videos\<folder>\<same filename>`. It creates the folder if it doesn't exist (`CreateDirectoryA`, a no-op if it's already there).
- It sorts manual recordings too (`RECORDING_STOPPED`), not just replays.

### How the folder name is chosen

**1. The folder name is the executable name, not the game's title.**
It takes the foreground window's process image path, e.g. `...\FortniteClient-Win64-Shipping.exe`, strips the directory and `.exe`, and drops the characters Windows forbids (`<>:"/\|?*`). So the folders are named `FortniteClient-Win64-Shipping`, `eldenring`, `SonsOfTheForest`, `SpeciesUnknown-Win64-Shipping`, `Reanimal`. There is **no mapping table** that turns exe names into titles. If you want pretty names, you would have to add one.

**2. Detection is a timeline, not a snapshot.** This was the key redesign.
- *Original July 4 version (the bug):* it looked at the foreground window **once**. For replays that happened at save time, so alt-tabbing to Discord and pressing Alt+Z filed the clip under `Discord`. For recordings it happened at **start** time, so starting on the desktop and then opening a game filed it under `Desktop`.
- *Aug 5 rewrite (current):* every **1 second** it records which exe has focus. On save, it looks **only at the part of the history that the clip actually covers**, and the app with the most weighted time wins.
  - Replay clip window = the buffer length read live from OBS (`max_time_sec`, 600 s on your profile). If it can't be read, it falls back to 120 s.
  - Recording window = real start-to-stop time.

**3. Three tiers of apps.**

| Tier | Members | Rule |
|---|---|---|
| `content` | anything not listed below (games, IDEs, browsers, terminals) | Always wins if present in the clip window |
| `overlay` (pass-through) | discord, obs64, obs, steam, steamwebhelper, epicgameslauncher, taskmgr, spotify, nvidia_share, overwolf, gameoverlayui, teamspeak3, slack | Only wins if **nothing** from `content` was focused during the clip |
| `desktop` (shell) | explorer, searchhost, searchapp, startmenuexperiencehost, shellexperiencehost, applicationframehost, dwm, lockapp, textinputhost, systemsettings | Never wins. If it's the only thing seen, the folder is `Desktop` |

Matching ignores case. The lists live near the top of the Lua file (`DESKTOP_APPS`, `OVERLAY_APPS`) and are the only thing you normally need to edit.

**4. Fullscreen counts double.** If the focused window covers ≥95% width and ≥90% height of the **primary** monitor, each of its seconds counts as 2.0 instead of 1.0. This is re-checked every sample, because a game can switch between fullscreen and windowed without getting a new window handle.

**5. Fallback chain when saving:**
1. best `content` app inside the clip window
2. otherwise best `overlay` app inside the window
3. otherwise whatever has focus **right now**, if it isn't a shell app
4. otherwise `Desktop`

Step 3 exists because right after OBS starts or the script reloads, the history is empty, so the first clip in the next minute or two uses a live snapshot.

**Outcomes this produces (all covered by tests):**
- desktop 20 s, then Fortnite fullscreen → `FortniteClient-Win64-Shipping`
- Fortnite, then 8 s of Discord, then save → still Fortnite
- only Discord for the whole clip → `Discord` (it really is the subject)
- only explorer → `Desktop`
- a game you played **before** the clip window started → ignored

### Why it's cheap (you asked for minimum resource use)

Measured on your machine with `bench-focus-probe.cs` and the Lua timing tests:
- It runs on OBS's **script thread**. That is not the render or encode path, so it can't cause dropped frames.
- Full probe (window → PID → exe path) ≈ **33 µs**. That lookup is **cached per window handle**, so while you stay in one game each sample is one `GetForegroundWindow` call, a pointer compare, and the ~0.05 µs rectangle check.
- History is **run-length encoded**: one entry per continuous stretch of focus, with a new entry only after an alt-tab or a gap of more than 5 s. An hour in one game is **one table entry**. History older than 1 h is discarded.
- The ffi buffers are allocated once, so sampling never allocates memory.

### Known quirks

- **Terminals, browsers and IDEs count as `content`.** Your Sep 13 test clip went to `Videos\claude\` because the Claude terminal had focus. If that bothers you, add those exe names to `OVERLAY_APPS`.
- The fullscreen check only compares against the **primary** monitor.
- **Confirmed bug: two saves in the same minute collide.** `FilenameFormatting=%b %d %I.%M %p` only goes down to the minute, so two Alt+Z presses within one minute both produce `rb Sep 21 09.14 PM.mp4`. The first one moves fine. For the second, `os.rename` refuses to overwrite, so it stays in `Videos\` root and `move failed` shows up in the script log. Verified 2026-09-24: `Videos\rb Sep 21 09.14 PM.mp4` (163 MB) is stuck in root, and a different 994 MB file with the same name is in `FortniteClient-Win64-Shipping\`. Fix: add seconds to the filename format (`%b %d %I.%M.%S %p`), or have `M.move_to_folder` add a ` (2)` suffix when the target exists.
- Folder names are raw exe names, and there's no title mapping.

### Tests

```
cd C:\Users\blare\Scripts
lua    test-obs-sort.lua     # 19 scoring cases, no OBS needed      -> 19 passed (run 2026-09-24)
luajit test-obs-win32.lua    # real win32 probe + stubbed OBS API   -> 7 passed  (run 2026-09-24)
```

The scoring half of the Lua file is written as pure functions and exported as the global `OBS_CLIP_SORT`, and it skips the win32/ffi code when `obslua` isn't present. That's what lets the tests run in plain Lua with no OBS.

---

## System B: visual classifier for already-misfiled clips

### Why it exists

Because of the snapshot bug, older clips piled up in the wrong folders, about **45 GB in `Desktop`** plus some in `Discord`, `Notepad` and `ApplicationFrameHost`, even though many were actually Fortnite or Elden Ring. System A only fixes **new** clips, so you asked on 2026-08-05 whether the existing folders could be sorted by what's actually in the video.

### How it works (`sort_clips.py`)

1. **Ground truth = folders that were already right.** `REFERENCE_FOLDERS`: `eldenring`, `FortniteClient-Win64-Shipping`, `SonsOfTheForest`, `Reanimal`, `SpeciesUnknown-Win64-Shipping`.
2. **Hand-checked examples** (`REFERENCE_OVERRIDES`) for classes that can't come from a folder, especially a **`Desktop` class** built from 5 verified non-game clips, and `Dead Space`. Without a Desktop class, desktop footage was forced into whichever game was closest. That was the biggest source of errors.
3. **Frame sampling:** 24 frames spread across each video, skipping the first and last 5% (loading screens and alt-tabs). It uses ffmpeg **input-side seeks** run 12 at a time. That cut the time from about 182 s to 4.5 s per video, roughly 40x faster.
4. **Fingerprint per frame:** a 64x36 thumbnail, then HSV histograms (hue weighted by saturation) plus an 8x8 edge-energy grid, normalized. Histograms ignore where things are on screen, so they hold up across maps and sessions. Edge energy separates busy 3D scenes from flat UI.
5. **Voting:** each frame votes for the label whose 3 nearest reference frames are closest (k-NN, k=3). The clip gets the majority label. That mirrors System A's "dominant content wins" rule.
6. **Safety rules:**
   - A file only moves if the winning label has **≥60% of the votes** (`MIN_CONFIDENCE`).
   - Classes with fewer than **3 example videos** can't be targets (`MIN_REF_VIDEOS`).
   - Hand-verified reference clips are never moved.
   - Existing files at the destination are skipped, never overwritten.
   - `SKIP_FOLDERS`: `Captures`, `clips`, `claude`.
   - Only `SUSPECT_FOLDERS` (`Desktop`, `ApplicationFrameHost`, `Discord`, `Notepad`) are candidates for reclassification.
7. **Fingerprint cache:** `Videos\.clipsort-cache.json`. Progress goes to `Scripts\clipsort-progress.log`.

```
python sort_clips.py scan      # build/cached reference fingerprints (--force to rebuild)
python sort_clips.py plan      # dry run, prints what would move
python sort_clips.py apply     # actually moves files
python sort_clips.py verify "C:\...\clip.mp4"   # per-frame vote breakdown
```

Needs `ffmpeg`/`ffprobe` on PATH plus `numpy` and `Pillow`. There's no ML runtime. (A local Ollama vision model was tried first but hung, so it was dropped.)

### How it was tuned (helper scripts, all from 2026-08-05)

| Script | What it did |
|---|---|
| `validate_clips.py` | Leave-one-video-out: each video classified against all the others. First version scored 65%. |
| `sweep_clips.py` | Threshold sweep. Showed that tuning thresholds couldn't fix it (either 0 wrong / 54% right or 89% right / 6 wrong), so the **features** were the problem. |
| `cache_thumbs.py`, `search_features.py` | Cached 1296 thumbnails and compared feature types. The color-layout grid scored 78%, **HSV + gradient with k=3 scored 93%**. |
| `tune_rule.py` | Compared decision rules (k-NN, margins) on the cached signatures (`_sweep-sigs.json`). |
| `accuracy_big.py` | **96% accuracy / 98% precision at 0.60** on classes with ≥3 videos. |
| `show_misses.py`, `verify_all.py`, `verify_low_conf.py`, `contact_sheet.py`, `montage.py` | Built contact sheets of each planned move so a human (or AI) could check them visually before anything moved. |

A visual review of the dry run caught 3 wrong calls, all at ≤79% confidence (Dead Space labeled as Elden Ring, and desktop screens labeled as games). That's why the Desktop and Dead Space override classes were added. After that, the review pages showed all correct.

### Was it ever applied? Probably not

The Aug 5-6 session ends **in the middle of the visual review** (montage page 5), and there's no record of `apply` being run. The `D:\PreReset-Backup\Videos` snapshot from Sep 20 still has **29 files in `Desktop`**, 3 in `Discord`, 1 in `Notepad`, and 1 in `ApplicationFrameHost`. So assume the old misfiled clips were **never moved**. If you want them sorted, run `plan`, review, then `apply`, against wherever those clips live now.

Current state: `C:\Users\blare\Videos` only has `FortniteClient-Win64-Shipping\`, an empty `Captures\`, and one unsorted clip. The older per-game folders (eldenring, SonsOfTheForest, Desktop, etc.) exist only in `D:\PreReset-Backup\Videos`. System B's reference folders point at `C:\Users\blare\Videos`, so it **won't find its training data** until those folders are copied back or `VIDEOS` in `sort_clips.py` is pointed at the backup.

---

## Rebuilding this from scratch (for an AI with no memory)

1. Put `obs-replay-flush.lua` in OBS → Tools → Scripts. It needs OBS's built-in LuaJIT with ffi, which OBS ships.
2. Make sure the replay buffer path and the recording path are the same folder (`Videos`). The script moves files relative to wherever OBS saved them.
3. To change what counts as a pass-through, edit `OVERLAY_APPS` and `DESKTOP_APPS`. Add a folder-name mapping in `M.sanitize` or `M.move_to_folder` if you want pretty names.
4. After any edit, run `lua test-obs-sort.lua` and `luajit test-obs-win32.lua`, then click reload in the OBS Scripts window.
5. For old misfiled clips, use `sort_clips.py`: `scan` → `plan` → look at contact sheets of anything under ~80% confidence → `apply`. **Never apply without the visual check.** A wrong move is worse than leaving a file where it is.
