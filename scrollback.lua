--[[--
本地滚动(Scrollback): 把"滚出屏幕顶部的行"攒进 Lua 侧历史栈, ↑/↓ 改成翻历史。

登记走官方 pushline4 回调(带 continuation 位, 区分"整行滚出"与"折行续行")。
这版 libvterm 的整行滚屏虽然走 premove 路径, pushline4 在这些路径上仍逐行触发
(实测), 因此不需要额外接 moverect。

翻看时把实时屏和翻看屏分开:
  live —— 跟远端同步的屏幕快照(每帧从 libvterm 读);
  view —— 往上翻了 offset 行后的画面, 只用于渲染。
往上翻: 历史栈顶行补到 view 顶, view 顶行压回历史栈顶;
往下翻: view 顶行入栈, 历史栈顶补到 view 底;
offset 回到 0 → 直接渲染 live, 实时输出照常滚动。
libvterm 没有写回格子的 API, 所以重排只在渲染层, 不回灌状态机
(翻看时远端输出仍进 live, 退出翻看立刻看到最新画面)。
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
        lines = {}, -- 历史: [1 .. #lines], 末尾 = 紧贴屏幕上方的那行
        mode = "push",
        offset = 0, -- 往上翻了几行; 0 = 看实时输出
        view = {},  -- 翻看屏行: view[r] = cells(r 从 0 起)
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
    self.view = {}
    self.offset = 0
end

function Scrollback:depth()
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

function Scrollback:popCells()
    return table.remove(self.lines)
end

function Scrollback:_onPushline(cells, continuation)
    local copy = ffi.new("VTermScreenCell[?]", self.cols)
    ffi.copy(copy, cells, ffi.sizeof("VTermScreenCell") * self.cols)
    self:pushCells(copy)
    return 1
end

-- ==================== 翻看 ====================

-- 把翻看屏初始化成当前实时屏, 再按 offset 调整
function Scrollback:_loadView()
    for r = 0, self.rows - 1 do self.view[r] = self:saveRow(r) end
end

-- 往上翻 n 行; 历史取完就到最早一屏停住(返回实际翻了行数)。
-- 屏幕内容整体下移: 底部留空由下一行历史填, 顶行滑出视图顶部
-- (不压回历史栈 —— 否则"上翻→下翻"会把行来回搬运, 永远翻不完)。
function Scrollback:scrollUp(n)
    n = n or 1
    if self.offset == 0 then self:_loadView() end
    local moved = 0
    for _ = 1, n do
        local cells = self:popCells()
        if not cells then break end
        for r = self.rows - 1, 1, -1 do self.view[r] = self.view[r - 1] end
        self.view[0] = cells
        self.offset = self.offset + 1
        moved = moved + 1
    end
    return moved
end

-- 往下翻 n 行; 回到 0 就恢复实时输出
function Scrollback:scrollDown(n)
    n = n or 1
    if self.offset == 0 then return 0 end
    local moved = 0
    for _ = 1, n do
        if self.offset == 0 then break end
        local top = self.view[0]
        for r = 0, self.rows - 2 do self.view[r] = self.view[r + 1] end
        self.view[self.rows - 1] = self:_blankRow()
        if top then self:pushCells(top) end -- 上翻时取走的历史行原样放回栈顶
        self.offset = self.offset - 1
        moved = moved + 1
        if self.offset == 0 then self.view = {} break end
    end
    return moved
end

-- 渲染层取行: 翻看时取 view, 否则实时屏
function Scrollback:rowCells(row)
    if self.offset > 0 then return self.view[row] end
    return nil
end

return Scrollback
