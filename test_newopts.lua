-- 五项优化无头回归: scrollback 容量参数化 / 残留进程收割。
--   cd ~/koreader && ./luajit <插件目录>/test_newopts.lua
local here = (arg and arg[0] or "."):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local ffi = require("ffi")
local VTermFFI = require("vterm_ffi")
local Scrollback = require("scrollback")
local PTY = require("pty")

local lib = VTermFFI.load(here)
local pass, fail = 0, 0
local function check(name, fn)
    local ok, detail = pcall(fn)
    if ok then pass = pass + 1; print("PASS " .. name)
    else fail = fail + 1; print("FAIL " .. name .. " | " .. tostring(detail)) end
end

-- 1. scrollback 容量参数化: 默认 2000, 显式传入生效
check("sb 默认容量 2000", function()
    local vt, screen = VTermFFI.newTerminal(lib, 3, 8)
    local sb = Scrollback.new(lib, vt, screen, 3, 8):install()
    assert(sb.max_lines == 2000, "默认 max_lines=" .. tostring(sb.max_lines))
end)

check("sb 自定义容量生效(裁剪最旧行)", function()
    local vt, screen = VTermFFI.newTerminal(lib, 2, 8)
    local sb = Scrollback.new(lib, vt, screen, 2, 8, 3):install()
    for i = 1, 5 do
        local cells = ffi.new("VTermScreenCell[?]", 8)
        for c = 0, 7 do
            cells[c].chars[0] = string.byte("a") + (i % 26)
            cells[c].width = 1
        end
        sb:pushCells(cells)
    end
    assert(sb:depth() == 3, "depth=" .. tostring(sb:depth()))
    assert(sb.max_lines == 3)
end)

-- 2. 残留进程收割: 活进程探活返回 true, 死 pid/非法 pid 返回 false
check("reapStale: 活 shell 收割返回 true", function()
    local pty = PTY.new()
    local ok, pid = pty:spawn("/bin/sh", nil, 24, 80)
    assert(ok, "spawn failed: " .. tostring(pid))
    -- 不 close, 模拟"KOReader 崩溃后 shell 残留"
    assert(PTY.reapStale(pid), "活进程应返回 true")
    -- 会话首进程组被 TERM, 稍等后应死亡
    os.execute("sleep 0.3")
    assert(not pty:isAlive(), "收割后 shell 应已退出")
    pty:close()
end)

check("reapStale: 死 pid 返回 false", function()
    assert(PTY.reapStale(999999) == false, "不存在进程应 false")
    assert(PTY.reapStale(nil) == false and PTY.reapStale(-5) == false, "nil/负 pid 应 false")
end)

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
