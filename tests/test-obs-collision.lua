-- Regression test: two saves with the same name must both get sorted.
-- Run: luajit test-obs-collision.lua   (needs ffi, like test-obs-win32.lua)
local ok_ffi = pcall(require, "ffi")
if not ok_ffi then print("SKIP: needs LuaJIT"); os.exit(0) end

obslua = {
    obs_frontend_add_event_callback = function() end,
    timer_add = function() end, timer_remove = function() end,
}
local dir = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
assert(loadfile(dir .. "/../obs-replay-flush.lua"))()
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

-- Non-ASCII user names / game names (UTF-8 from OBS) must move too.
-- Written as UTF-8 bytes so the source file stays ASCII.
local uroot = root .. "\\Jos\195\169"            -- José
local uclip = uroot .. "\\rb Sep 21 09.15 PM.mp4"
-- io.open can't create a UTF-8 path on an ANSI code page, so build the
-- fixture through the script's own W-API wrappers.
local uok = pcall(function()
    M.win.mkdir(uroot)
    write(root .. "\\tmp.mp4", "utf8")
    assert(M.win.move(root .. "\\tmp.mp4", uclip))
end)
if uok then
    M.move_to_folder(uclip, "\195\137lden Ring")   -- Élden Ring
    check("utf-8 source + folder moved",  M.win.exists(uroot .. "\\\195\137lden Ring\\rb Sep 21 09.15 PM.mp4"))
    check("utf-8 source gone",            not M.win.exists(uclip))
else
    print("SKIP  utf-8 path case (could not create fixture)")
end

os.execute('rmdir /s /q "' .. root .. '"')
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
