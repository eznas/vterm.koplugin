--[[--
本地滚动(Scrollback): 把"滚出屏幕顶部的行"攒进 Lua 侧历史日志, ↑/↓ 改变视口偏移。

登记走官方 pushline4 回调(带 continuation 位, 区分"整行滚出"与"折行续行")。
这版 libvterm 的整行滚屏虽然走 premove 路径, pushline4 在这些路径上仍逐行触发
(实测), 因此不需要额外接 moverect。

翻看时:
  offset = 0: 直接渲染 live 实时屏, 实时输出照常滚动。
  offset > 0: 虚拟行连续映射:
    虚拟行 1 .. #lines 为历史行 (1=最旧, #lines=紧邻屏幕顶部)
    虚拟行 #lines+1 .. #lines+rows 为进入翻看时的 live 屏快照
    第 row 行显示: 虚拟行 (#lines - offset) + 1 + row
  下翻/上翻纯按 offset 寻址, 零丢行、零空白洞、不破坏历史栈。
]]

local ffi = require("ffi")

local Scrollback = {}
Scrollback.__index = Scrollback

local DEFAULT_MAX_LINES = 2000 -- 默认历史行上限: 40B/cell × cols, 80 列约 6.4MB

local function cpIsInk(cp)
    return cp ~= 0 and cp ~= 32 and cp ~= 0xFFFFFFFF
end

function Scrollback.new(vt_lib, vt, screen, rows, cols, max_lines)
    local self = setmetatable({
        lib = vt_lib,
        vt = vt,
        screen = screen,
        rows = rows,
        cols = cols,
        max_lines = max_lines or DEFAULT_MAX_LINES,
        lines = {},    -- 历史日志: [1 .. #lines], 1=最早, 末尾=紧贴屏幕上方的那行
        offset = 0,    -- 往上翻了几行; 0 = 看实时输出
        snapshot = nil,-- 翻看时的实时屏快照: [0 .. rows-1]
        _cell = ffi.new("VTermScreenCell"),
        _pos = ffi.new("VTermPos"),
    }, Scrollback)
    self._pushline4 = ffi.cast("flat_pushline_fn", function(cols_, cells, continuation, user)
        return self:_onPushline(cells, continuation)
    end)
    return self
end

-- main.lua 在 libvterm 初始化后调用一次
function Scrollback:install()
    self.lib.vterm_bridge_set_scrollhooks(self.screen, nil, self._pushline4, nil)
    return self
end

function Scrollback:reset(rows, cols)
    self.rows = rows or self.rows
    self.cols = cols or self.cols
    self.lines = {}
    self.snapshot = nil
    self.offset = 0
end

function Scrollback:depth()
    return #self.lines - self.offset
end

function Scrollback:totalLines()
    return #self.lines
end

function Scrollback:isScrolling()
    return self.offset > 0
end

-- ==================== 屏幕行读写 ====================

function Scrollback:saveRow(row)
    local cells = ffi.new("VTermScreenCell[?]", self.cols)
    local cell, pos = self._cell, self._pos
    pos.row = row
    for c = 0, self.cols - 1 do
        pos.col = c
        self.lib.vterm_screen_get_cell(self.screen, pos, cell)
        cells[c] = cell
    end
    return cells
end

function Scrollback:_blankRow()
    return ffi.new("VTermScreenCell[?]", self.cols)
end

-- ==================== 历史登记 ====================

function Scrollback:pushCells(cells)
    for c = 0, self.cols - 1 do
        if cpIsInk(tonumber(cells[c].chars[0]) or 0) then
            self.lines[#self.lines + 1] = cells
            if #self.lines > self.max_lines then table.remove(self.lines, 1) end
            return true
        end
    end
    return false -- 纯空白行不进历史
end

function Scrollback:_onPushline(cells, continuation)
    local copy = ffi.new("VTermScreenCell[?]", self.cols)
    ffi.copy(copy, cells, ffi.sizeof("VTermScreenCell") * self.cols)
    if self:pushCells(copy) then
        if self.offset > 0 then
            self.offset = math.min(self.max_lines, self.offset + 1)
        end
    end
    return 1
end

-- ==================== 翻看 ====================

function Scrollback:_loadSnapshot()
    self.snapshot = {}
    for r = 0, self.rows - 1 do self.snapshot[r] = self:saveRow(r) end
end

-- 往上翻 n 行; 历史取完就到最早一屏停住(返回实际翻了行数)。
function Scrollback:scrollUp(n)
    n = n or 1
    local max_offset = #self.lines
    if self.offset >= max_offset then return 0 end
    if self.offset == 0 then self:_loadSnapshot() end
    local old = self.offset
    self.offset = math.min(max_offset, self.offset + n)
    return self.offset - old
end

-- 往下翻 n 行; 回到 0 就恢复实时输出
function Scrollback:scrollDown(n)
    n = n or 1
    if self.offset == 0 then return 0 end
    local old = self.offset
    self.offset = math.max(0, self.offset - n)
    if self.offset == 0 then self.snapshot = nil end
    return old - self.offset
end

-- 渲染层取行: 翻看时按虚拟坐标取行, 否则实时屏
function Scrollback:rowCells(row)
    if self.offset == 0 then return nil end
    local v = (#self.lines - self.offset) + 1 + row
    if v >= 1 and v <= #self.lines then
        return self.lines[v]
    elseif v > #self.lines and self.snapshot then
        local snap_idx = v - #self.lines - 1
        return self.snapshot[snap_idx]
    end
    return nil
end

return Scrollback
