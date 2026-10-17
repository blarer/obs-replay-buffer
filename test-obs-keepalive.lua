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
    K.fails, K.requested = 0, false
    active, available, starts, stops = true, true, 0, 0
    os.remove(M.request_file)
    script_load(nil)   -- sets loaded_at = now
end
M.request_file = (os.getenv("TEMP") or ".") .. "\\obs-restart-request-test"
os.remove(M.request_file)
local function request_exists()
    local fh = io.open(M.request_file, "r")
    if fh then fh:close(); return true end
    return false
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
check("2 failed starts: no restart request yet", request_exists(), false)

-- 8b) Start can never succeed (2026-10-17: NVENC failed to load at launch,
--     encoder missing). After 3 failed starts, ask the watchdog to restart OBS.
fresh(); tick(20)
obslua.obs_frontend_replay_buffer_start = function() starts = starts + 1 end  -- stays off
active = false
tick(1)                                          -- start #1
tick(10)                                         -- start #2 (1 failed)
tick(20)                                         -- start #3 (2 failed)
check("after 2 failed starts: no request", request_exists(), false)
tick(40)                                         -- start #4 (3 failed)
check("after 3 failed starts: restart requested", request_exists(), true)
os.remove(M.request_file)
tick(300)
check("request written only once per OBS run", request_exists(), false)
check("keeps retrying meanwhile", starts >= 5, true)
-- Recovers on its own (e.g. user fixed it): stale request is withdrawn.
M.request_restart("test")
obslua.obs_frontend_replay_buffer_start = function() starts = starts + 1; active = true end
tick(300)
check("buffer recovered", active, true)
tick(1)
check("recovery withdraws the restart request", request_exists(), false)
check("recovery resets the failure count", K.fails, 0)

-- 8c) A save flush is not a failure.
fresh(); tick(20)
for _ = 1, 5 do
    on_event(obslua.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED)
    active = false
    on_event(obslua.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED)
    do_start(); tick(30)
end
check("5 saves: no failures counted", K.fails, 0)
check("5 saves: no restart request", request_exists(), false)

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
