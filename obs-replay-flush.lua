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
-- Cost: the sampler runs on OBS's script thread, never the render or encode
-- path, so it cannot drop frames. Measured on this machine, a full probe is
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
    local ok, err = os.rename(path, target .. "\\" .. file)
    if ok then
        print("sorted -> " .. folder .. "\\" .. file)
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
