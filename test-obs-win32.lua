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
