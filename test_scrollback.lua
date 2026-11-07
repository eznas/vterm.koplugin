-- 本地滚动(Scrollback)无头回归: 直接驱动 scrollback.lua, 不依赖 KOReader UI。
--   cd ~/koreader && ./luajit <插件目录>/test_scrollback.lua
local here = (arg and arg[0] or "."):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local ffi = require("ffi")
local VTermFFI = require("vterm_ffi")
local Scrollback = require("scrollback")

local lib = VTermFFI.load(here)
local ROWS, COLS = 5, 16
local vt, screen = VTermFFI.newTerminal(lib, ROWS, COLS)

-- 模拟 main.lua 的接线顺序: 先 set_callbacks(damage/movecursor), 再装滚动钩子。
-- 断言滚动钩子不会把刷屏回调挤掉(重设整张 callbacks 表是个真实的坑)。
local damage_hits = 0
local bridge = ffi.new("VTermBridgeCallbacks")
bridge.damage = ffi.cast("damage_flat_fn", function(r1, r2, c1, c2, user)
    damage_hits = damage_hits + 1
    return 1
end)
bridge.movecursor = nil
bridge.bell = nil
bridge.user = nil
lib.vterm_bridge_set_callbacks(screen, bridge)

local sb = Scrollback.new(lib, vt, screen, ROWS, COLS):install()

local cell, pos = ffi.new("VTermScreenCell"), ffi.new("VTermPos")

local function decode(cp)
    if cp == 0 or cp == 32 or cp == 0xFFFFFFFF or cp == 0x7F then return " " end
    if cp < 128 and cp >= 32 then return string.char(cp) end
    return "?"
end

local function rowText(r)
    pos.row = r
    local t = {}
    for c = 0, COLS - 1 do
        pos.col = c
        lib.vterm_screen_get_cell(screen, pos, cell)
        t[#t + 1] = decode(tonumber(cell.chars[0]) or 0)
    end
    return (table.concat(t):gsub("%s+$", ""))
end

-- 渲染层可见行: 翻看时取 view, 否则实时屏
local function viewText(r)
    local cells = sb:rowCells(r)
    if cells then
        local t = {}
        for c = 0, COLS - 1 do t[#t + 1] = decode(tonumber(cells[c].chars[0]) or 0) end
        return (table.concat(t):gsub("%s+$", ""))
    end
    return rowText(r)
end

local function screenText()
    local t = {}
    for r = 0, ROWS - 1 do t[#t + 1] = viewText(r) end
    return table.concat(t, "|")
end

local function feed(s)
    lib.vterm_input_write(vt, s, #s)
    lib.vterm_screen_flush_damage(screen)
end

local pass, fail = 0, 0
local function ok(cond, msg)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        print("  FAIL: " .. msg)
    end
end

print("== 1. 逐行输出 line1..line9 ==")
for i = 1, 9 do feed("line" .. i .. "\r\n") end
print("  screen: " .. screenText())
print("  hist depth = " .. sb:depth())
ok(sb:depth() >= 4, "应攒到历史行, 实得 " .. sb:depth())
ok(screenText():find("line9", 1, true) ~= nil, "最新行应在屏上, 实得 " .. screenText())

print("== 2. 上翻 1 行: 更早的行从顶部补进来 ==")
local depth_before = sb:depth()
local top_before = viewText(0)
sb:scrollUp(1)
local after = screenText()
print("  screen: " .. after)
ok(sb:isScrolling(), "上翻后应处于滚动态")
ok(viewText(0) ~= top_before or sb:depth() < depth_before, "顶行应换成更早的内容")
ok(sb:depth() == depth_before - 1, "上翻一行后历史应少一行, 实得 " .. sb:depth())

print("== 3. 一直上翻到最早一屏后停住 ==")
local guard = 0
while sb:scrollUp(1) > 0 and guard < 2000 do guard = guard + 1 end
print("  翻了 " .. guard .. " 次, 剩余 hist = " .. sb:depth())
ok(guard < 2000, "翻屏不应死循环")
local top_oldest = viewText(0)
print("  oldest top = " .. top_oldest)
ok(top_oldest ~= "", "最早一屏顶部应有内容")

print("== 4. 下翻回到实时输出 ==")
local guard2 = 0
while sb:isScrolling() and guard2 < 2000 do
    sb:scrollDown(1)
    guard2 = guard2 + 1
end
print("  下翻 " .. guard2 .. " 次, offset = " .. sb.offset)
ok(sb.offset == 0, "应回到 offset 0")
ok(screenText():find("line9", 1, true) ~= nil, "回到实时输出后应看到最新行: " .. screenText())

print("== 5. 翻看期间远端继续输出, 退出翻看能看到新行 ==")
sb:scrollUp(2)
feed("after1\r\nafter2\r\n")
while sb:isScrolling() do sb:scrollDown(1) end
print("  screen: " .. screenText())
ok(screenText():find("after2", 1, true) ~= nil, "退出翻看应看到新输出: " .. screenText())

print("== 6. 超宽行折行后, 翻看能取回整行两段 ==")
feed("ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n")
local d = sb:depth()
local found = { first = false, second = false }
while sb:scrollUp(1) > 0 do
    for r = 0, ROWS - 1 do
        local t = viewText(r)
        if t:find("QRSTUVW", 1, true) then found.first = true end
        if t:find("XYZ", 1, true) then found.second = true end
    end
end
print("  depth=" .. d .. " first_seg=" .. tostring(found.first) .. " second_seg=" .. tostring(found.second))
ok(found.second, "翻看历史应能看到折行的第二段(XYZ)")
while sb:isScrolling() do sb:scrollDown(1) end

print(string.format("\n== 7. 装上滚动钩子后 damage 回调仍在 =="))
ok(damage_hits > 0, "damage 回调被滚动钩子挤掉了(hits=" .. damage_hits .. ")")

print(string.format("\nRESULT: %d pass / %d fail", pass, fail))
os.exit(fail == 0 and 0 or 1)
