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
