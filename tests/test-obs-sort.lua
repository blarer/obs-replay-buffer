-- Tests for obs-replay-flush.lua clip-folder scoring. Run: lua test-obs-sort.lua
-- No OBS required: the script skips the win32 layer when `obslua` is absent.

local dir = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
assert(loadfile(dir .. "/../obs-replay-flush.lua"))()
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
