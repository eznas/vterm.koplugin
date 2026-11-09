--[[--
VTerm 终端网格视图:继承 InputText 以复用 InputDialog / VirtualKeyboard 集成,
但渲染、输入与脏区管理完全接管。

集成三原则(对齐官方 terminal.koplugin 的 TermInputText):
1. init 绝不改动 self.dimen / self.width / self.height —— InputDialog 全屏模式
   依赖探针实例(for_measurement_only)诚实测高,谎报尺寸会造成布局残留空洞;
2. paintTo 把 libvterm 单元网格画进 InputText 文本区原点,并记录绝对坐标;
3. 局部刷新标脏到 self.parent(顶层对话框) —— UIManager 只重绘顶层 widget,
   标脏在子 widget 上永远无人消费,表现为"内容已到、屏幕从不刷新"。

中文输入(拼音/笔画 IME)沙箱:
KOReader 的 zh 键盘通过 util.wrapMethod 包装 inputbox 的 addChars/delChar 做
"原地候选"组词 —— 组合期间反复在缓冲区里写候选预览(如 你[妮泥…])再删除重写,
且内部编辑必须能走 inputbox.addChars:raw_method_call(实例字段必须保持其
WrappedFunction,覆盖即崩)。因此 VTermView 的 addChars/delChar 一律只写
本地草稿缓冲(绝不直接碰 PTY),提交统一走 UIManager:nextTick 合并 ——
同一次按键事件的 IME 删除+重写在事件收口后才结算,不会中途外泄:
  - 尾字符是 ']' → 候选预览未收口,组词中,不发;
  - 否则全部未发尾部一次性提交。
代价: IME 首字母落入的首候选(草稿)会先发后退格(需 PTY 置 IUTF8),
字节流自校正,最终内容正确。
]]

local Blitbuffer = require("ffi/blitbuffer")
local bit = require("bit")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local InputText = require("ui/widget/inputtext")
local RenderText = require("ui/rendertext")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local ffi = require("ffi")
local util = require("util")

local VTermView = InputText:extend{
    name = "VTermView",
    vt = nil,
    screen = nil,
    vt_lib = nil,
    rows = 24,
    cols = 80,
    font_size = 18,
    cell_w = 10,
    cell_h = 20,
    baseline = 15,
    face_mono = nil,
    face_cjk = nil,
    _inner_off = 0,
    _cell_tmp = nil,
    _pos_tmp = nil,
    _vt_sent = 0,          -- charlist 前缀中已提交到 PTY 的字符数(charlist 跨行累积)
    _vt_line_start = 0,    -- 当前行在 charlist 中的起点(上个回车时的 _vt_sent)
                           -- 行中光标模型: charpos = 光标在**当前行**内的位置(1..行长+1),
                           -- ←/→ 同步移动本地与 shell 光标; 打字/⌫ 按 charpos 插入/删除,
                           -- 全局下标 = _vt_line_start + charpos - 1
    _vt_bar_line = nil,    -- 输入条"本行中文镜像": 已提交内容(shell 回显为 ? 的部分)
    _vt_ctrl_pending = false,
    _vt_local = false,     -- 本地会话(busybox vi 字节级退格适配)
    _vt_dirty = nil,
    _vt_refresh_pending = false,
    _vt_write = nil,       -- main.lua 注入的 PTY 写入+回读闭包
    _vt_sb = nil,          -- scrollback.lua 实例(本地滚动历史)
    _vt_sb_mode = false,   -- ⇕ 翻页层: true=上下滑发 PgUp/PgDn(⇆关)/翻本地历史(⇆开)
    _vt_page_dir = nil,    -- ⇆关: 本次拖动已处理的翻页方向(pan 流与收尾 swipe 去重)
    _vt_arrows = false,    -- 方向手势开关: true=网格上滑动发方向键
    _vt_shift_mode = false,-- Shift 挂起状态缓存(跨键盘收起/全屏持久化)
    _vt_arrow_ges = nil,   -- 已注册的手势对象(关闭时摘除)
    STABLE_PX = 12,        -- 手指停住判定阈值(px): 位移小于此视为抖动, 不重置停顿计时
    SWIPE_UNIT = 120,      -- 同向拖动累计多少像素才发一发(防误触/刷屏; 约两行字高)
    REPEAT_DELAY = 1.0,    -- 停住满多少秒开始连发
    REPEAT_PERIOD = 0.2,   -- 连发周期(秒): 5 次/秒(用户定稿)
    REPEAT_MOVE_PX = 80,   -- 连发期间判"真移动"的步长门槛(px): 小于此的抖动不打断连发
    _vt_collapsed = false, -- ⌨ 收起态(按钮栏+软键盘全收): tap 网格唤回
    _vt_toggle_cb = nil,   -- main.lua 注入的收放切换回调
    _vt_extra_h = 0,       -- 收起手术后额外占位高度(原按钮栏空间, 网格扩展区)
}

-- 收起手术后: vgroup 排版时让 view 多占 _vt_extra_h(原按钮栏的空间),
-- 否则网格扩展行会画进 vgroup 之外的区域留下按钮栏残影。
function VTermView:getSize()
    local sz = InputText.getSize(self)
    if self._vt_extra_h and self._vt_extra_h > 0 then
        sz = sz:copy()
        sz.h = sz.h + self._vt_extra_h
    end
    return sz
end

function VTermView:init()
    -- 字号用户可调(G_reader_settings 持久化, main.lua 设置入口写), 默认 18
    local G_reader_settings = rawget(_G, "G_reader_settings")
    local saved_fs = G_reader_settings and G_reader_settings:readSetting("vterm_font_size")
    if saved_fs then self.font_size = saved_fs end -- 类默认 18 在场, 有存值即覆盖

    InputText.init(self)

    -- InputDialog 会先造一个 for_measurement_only 探针实例测行高,
    -- 探针的 rows/cols 无意义,字体测量也不必做
    if self.for_measurement_only then return end

    -- 西文等宽字体 + 中文 CJK 字体(KOReader 内置 noto/NotoSansCJKsc)
    self.face_mono = Font:getFace("DroidSansMono.ttf", self.font_size)
        or Font:getFace("infont", self.font_size)
    self.face_cjk = Font:getFace("NotoSansCJKsc-Regular.otf", self.font_size)
        or self.face_mono

    -- 测量单宽基准单元格(getFace 内部已按 DPI 缩放)
    local glyph_m = RenderText:getGlyph(self.face_mono, string.byte("M"), false)
    self.cell_w = glyph_m and glyph_m.ax or math.floor(self.font_size * 0.6)
    local h, asc = self.face_mono.ftsize:getHeightAndAscender()
    self.cell_h = math.ceil(h)
    self.baseline = math.floor(asc + 0.5)

    -- 候选字条: 独立窄条带, 固定在分配区最底(下沿=键盘按钮行), 与上方网格
    -- 绝不重叠 —— 候选字永远不遮挡终端输出。条带高度按 CJK 字形实际墨高
    -- + 西文降部预留(字体行高含大量上下留白, 直接用它会把文字顶得离键盘
    -- 很远并白吃一整行); 上沿一条细线紧贴网格末行。
    local g_cjk = RenderText:getGlyph(self.face_cjk, 0x5019, false) -- 候
    local g_desc = RenderText:getGlyph(self.face_cjk, 0x67, false)  -- g
    self.cjk_ink_h = (g_cjk and g_cjk.bb:getHeight()) or math.ceil(self.cell_h * 0.85)
    self.cjk_ink_t = (g_cjk and g_cjk.t) or math.floor(self.cell_h * 0.7) -- 基线到墨迹顶
    self.cjk_desc = math.max(0, (g_desc and (g_desc.bb:getHeight() - g_desc.t)) or 0)
    self.bar_face = self.face_cjk -- 文字大小不变(用户明确要求)
    self.bar_h = math.max(6, self.cjk_ink_h + self.cjk_desc + 6)
    self.bar_h_full = self.bar_h -- 条带全高; 非 IME 布局归零给网格腾行
    self.cols = math.max(20, math.floor(self.width / self.cell_w))
    self.avail_rows_h = math.max(self.bar_h, self.height - self.bar_h)
    self.rows = math.max(3, math.floor(self.avail_rows_h / self.cell_h))

    -- InputText 结构: FrameContainer(margin+bordersize+padding) > TextBoxWidget
    -- 网格从该内边距之后起画
    self._inner_off = (self.margin or 0) + (self.bordersize or 0) + (self.padding or 0)

    self._cell_tmp = ffi.new("VTermScreenCell")
    self._pos_tmp = ffi.new("VTermPos")

    -- 输入沙箱: 类方法只做草稿缓冲, 提交由事件边界按差分判定
    self._vt_sent = 0
    self:_watchKeyboardLayout()
    if rawget(self, "addChars") then
        self:_wrapImeFunc()           -- zh 系布局: IME wrapped 已在场
        self._vt_bar_visible = true   -- IME 布局显示输入条
    else
        self:_installInputBoundary()  -- en 等: 兜底边界
        self._vt_bar_visible = false  -- 直通布局隐藏输入条
    end
    -- 条带高度按布局生效(EN 布局 grid 多吃 1~2 行); init 时无需 resize 回调
    self:_vt_setBarVisible(self._vt_bar_visible)
end

-- 条带按布局自适应: IME 布局保留全高(组词/候选唯一绘制处), 直通布局归零。
-- 返回 rows 是否变化(调用方负责 vterm_set_size + pty winsize 同步)。
function VTermView:_vt_setBarVisible(visible)
    local target = visible and (self.bar_h_full or 0) or 0
    if (self.bar_h or 0) == target then return false end
    self.bar_h = target
    local old_rows = self.rows
    self.avail_rows_h = math.max(self.bar_h, self.height - self.bar_h)
    self.rows = math.max(3, math.floor(self.avail_rows_h / self.cell_h))
    self:refreshInputBar()
    -- 条带收放必须显式刷掉旧像素: rows 未变时 _applyTerminalSize 早退、
    -- refreshInputBar 在 bar_h<=0 短路——旧条带+候选浮层无人重绘, 残影
    -- 留在功能键上沿(e-ink 局部刷新语义: 刷新区必须覆盖旧像素)。
    -- 全幅脏区(含下内边距到条带下沿)≥60% 网格面积, _vtFlush 自动升 ui 波形。
    if self.dimen and self.dimen.x then
        self:queueDirty(Geom:new{
            x = self.dimen.x, y = self.dimen.y,
            w = self.dimen.w,
            h = self.dimen.h + 2 * (self._inner_off or 0),
        })
    end
    return self.rows ~= old_rows
end

-- 布局切换善后: stock KOReader 在 🌐 切到非 IME 布局(如 en)时不会摘除
-- zh 系 IME 挂在 inputbox 上的包装, 英文字母会继续进拼音组词。
-- 这里包装 keyboard 实例的 setKeyboardLayout, 切到无 IME 布局时调用
-- VirtualKeyboard 保存的官方解包闭包 uwrap_func(revert 全部包装并清标志,
-- 切回 zh 系时 stock 会重新包装, 完全对称)。
function VTermView:_watchKeyboardLayout()
    local kb = self.keyboard
    if not kb or not kb.setKeyboardLayout or rawget(kb, "_vt_layout_watched") then return end
    rawset(kb, "_vt_layout_watched", true)
    local orig_set = kb.setKeyboardLayout
    kb.setKeyboardLayout = function(k, layout, ...)
        orig_set(k, layout, ...)
        self:_syncImeWrapper(layout)
    end
end

function VTermView:_syncImeWrapper(new_layout)
    local kb = self.keyboard
    if not kb then return end
    local mod_name = kb.lang_to_keyboard_layout and kb.lang_to_keyboard_layout[new_layout]
    if mod_name then
        local ok, mod = pcall(require, "ui/data/keyboardlayouts/" .. mod_name)
        if ok and mod and mod.wrapInputBox then
            self:_wrapImeFunc() -- VK:init 刚包装完新 IME, 把它的 func 纳入边界
            self._vt_bar_visible = true
            if self:_vt_setBarVisible(true) and self._vt_resize_cb then
                self._vt_resize_cb() -- rows 变了: 网格/PTY winsize 同步
            end
            return
        end
    end
    if kb.uwrap_func then
        kb.uwrap_func()
        kb.uwrap_func = nil
    end
    -- 关键: 摘掉 IME 后类方法重新裸露, 必须重装兜底边界, 否则 EN 字符
    -- 只进草稿缓冲无人提交, 表现为"切换英文后无法输入"
    self:_installInputBoundary()
    -- EN 布局隐藏输入条(用户要求), 并清掉中文残留
    self._vt_bar_visible = false
    if self:_vt_setBarVisible(false) and self._vt_resize_cb then
        self._vt_resize_cb() -- rows 变了: 网格/PTY winsize 同步
    end
    self._vt_bar_line = nil
    self.charpos = nil -- EN 切换: 光标模型重置(下次 ←/→ 重新初始化)
    local n = #self.charlist
    if n > self._vt_sent then self._vt_sent = n end -- 丢弃未提交残留
    self:refreshInputBar()
end

-- ==================== 触摸鼠标(SGR 序列翻译) ====================
-- 应用(vim mouse=a 等)开启 DECSET 鼠标上报后(pty.lua 跟踪), 触摸手势
-- 翻译成 SGR 鼠标序列: tap=点击(移动光标), 拖动=按住移动, 上下滑=滚轮。
-- ⚠️⇆ 开启时滑动让位普通键(方向/PgUp/PgDn/Shift+翻页), 鼠标只保留 tap
-- 点击——滑动被鼠标滚轮/拖动抢占是冲突, 用户定稿 2026-11-08。

function VTermView:_mouseActive()
    return self.pty and (self.pty.mouse_click or self.pty.mouse_drag) and true or false
end

-- 屏幕坐标 → 1-based 网格单元格(SGR 鼠标坐标)
function VTermView:_mouseCell(pos)
    local off = self._inner_off
    local col = math.floor((pos.x - self.dimen.x - off) / self.cell_w) + 1
    local row = math.floor((pos.y - self.dimen.y - off) / self.cell_h) + 1
    col = math.max(1, math.min(self.cols, col))
    row = math.max(1, math.min(self.rows, row))
    return { col = col, row = row }
end

function VTermView:_mouseSend(btn, pressed, cell)
    if not cell then return end
    if self.pty and self.pty.mouse_sgr then
        -- SGR 格式(应用开了 ?1006)
        self:sendBytes(string.format("\27[<%d;%d;%d%s", btn, cell.col, cell.row, pressed and "M" or "m"))
    else
        -- X10 兜底(远端旧 vim 只开 ?1000/?1002): ESC[M 前缀 + 单字节编码,
        -- 坐标 +32 偏移, 释放=btn+3; 网格远小于 223, 不会撞 255 哨兵
        self:sendBytes(string.format("\27[M%c%c%c",
            btn + (pressed and 32 or 35), cell.col + 32, cell.row + 32))
    end
end

-- ANSI 16 色的近似亮度(xterm 默认色板, e-ink 灰阶映射用)
local _ANSI16_LUM = { 0, 61, 121, 182, 22, 84, 143, 205, 85, 76, 149, 226, 28, 104, 178, 255 }
local _CUBE_LV = { 0, 95, 135, 175, 215, 255 }

-- indexed 色 → 亮度(xterm 256 色板: 0-15 标准, 16-231 6x6x6 立方, 232-255 灰阶)
local function indexedLum(idx)
    if idx >= 232 and idx <= 255 then
        return 8 + (idx - 232) * 10
    elseif idx < 16 then
        return _ANSI16_LUM[idx] or 0
    end
    local i = idx - 16
    local lv = _CUBE_LV
    return math.floor((lv[math.floor(i / 36) + 1] * 30
        + lv[math.floor((i % 36) / 6) + 1] * 59
        + lv[i % 6 + 1] * 11) / 100)
end

-- cell 背景色 → e-ink 灰阶 Color8(无背景返回 nil)。
-- 位定义(libvterm vterm.h): TYPE_MASK=0x01(0=RGB,1=INDEXED),
-- DEFAULT_FG=0x02, DEFAULT_BG=0x04。
-- ⚠️ 深色背景(亮度<100)不画: libvterm 默认 pen 的 bg = RGB(0,0,0) 黑
-- (vterm 库暗色终端约定, state.c:163), vim 历史行的格子都带这种 RGB 黑
-- 背景 → 按亮度渲染会把整屏历史涂黑(真机黑屏实证)。
-- 本地 vim VISUAL 选区 = indexed 248; 远端 vim 选区色可能是任意 indexed
-- (含 reverse), 只要有浅色背景就渲染灰底黑字。
function VTermView:_cellBgGray(cell)
    local bg = cell.bg
    if not bg then return nil end
    local t = bg.type
    if bit.band(t, 0x04) ~= 0 then return nil end -- DEFAULT_BG: 不画背景
    if bit.band(t, 0x01) == 0x01 then -- INDEXED
        local lum = indexedLum(bg.indexed.idx)
        -- indexed 深色是应用有意的深色高亮(远端 vim Visual 选区 ctermbg=238
        -- 等, 属性探针实证), e-ink 上黑底黑字无法分辨 → 重映射浅灰底黑字
        if lum < 100 then return Blitbuffer.Color8(180) end
        return Blitbuffer.Color8(lum)
    end
    local lum = math.floor((bg.rgb.red * 30 + bg.rgb.green * 59 + bg.rgb.blue * 11) / 100)
    if lum < 100 then return nil end -- RGB 深色 = 库默认黑 pen(state.c:163), 不画防全屏涂黑
    return Blitbuffer.Color8(lum)
end

-- 防止点击终端画布时原生 InputText 移动单行光标;
-- 收起状态(⌨ 把按钮栏+软键盘全收)下 tap 网格 = 唤回(重建路径, 走 main 注入的回调),
-- 唤回前先滚回实时帧(翻看态下打字, shell 回显会被历史帧遮住)。
-- 鼠标模式: tap = 抬起(按下由 touch 发) → vim 收到完整点击(移动光标/选词)。
function VTermView:onTapTextBox(arg, ges)
    self:_gesLog("TAP collapsed=" .. tostring(self._vt_collapsed)
        .. " pos=" .. tostring(ges.pos and (ges.pos.x .. "," .. ges.pos.y) or "nil"))
    if self._vt_collapsed and self._vt_toggle_cb then
        self:_ensureLive()
        self._vt_toggle_cb()
        return true
    end
    -- 鼠标模式点击: touch 事件 pos=nil(真机 ges.log 实证) → _vt_mouse_down
    -- 不会经 onVTermTouch 建立, tap 自带完整坐标 → 在 tap 处直接按下+释放
    if self:_mouseActive() and ges.pos and not self._vt_collapsed then
        local r = self:_gridRegion()
        if r:contains(ges.pos) then
            self:_ensureLive()
            local cell = self:_mouseCell(ges.pos)
            self:_mouseSend(0, true, cell)
            self:_mouseSend(0, false, cell)
            self._vt_mouse_down = nil
            return true
        end
    end
    return true
end

-- ==================== 输入沙箱(IME 安全) ====================

-- 草稿缓冲追加(UTF-8 逐字)
function VTermView:_bufAppend(chars)
    local list = util.splitToChars(chars)
    for i = 1, #list do
        table.insert(self.charlist, list[i])
    end
    self.charpos = #self.charlist - (self._vt_line_start or 0) + 1 -- 行内相对
end

-- 输入事件边界: 键盘 tap 经 inputbox.addChars/delChar 入口, 入口外层包一层
-- "事件收口", 收口处按缓冲差分把已定稿内容提交给 PTY。
-- 分层:
--   zh 系布局: IME 先把实例字段包装成 WrappedFunction(内部编辑走 raw_method_call
--             直达类方法, 绕过一切 func 层) —— _wrapImeFunc 在其 func 外再包边界,
--             并打 _vt_ime_active 标记;
--   en 等布局: 无 IME, _installInputBoundary 用 util.wrapMethod 挂边界。
-- 边界层的 END 调用带 IME 活跃检查: IME 内部 raw 写入(组词/候选预览)若途经
-- 兜底层, 一律静默 —— 只有键盘事件收口才做提交判定。
-- 差分规则(_vtKeyEventEnd):
--   尾字符 ']'              → 候选预览未收口, 组词中, 不发;
--   净增且增量 ≠ 所按字符   → IME 组词写入(含首字母裸候选), 不发;
--   净增且增量 == 所按字符  → 直通字符(空格/回车/标点), 发送;
--   净零/净减               → 分隔键提交/组词收口, 发送未发尾部。
function VTermView:_installInputBoundary()
    local cur = rawget(self, "addChars")
    if type(cur) == "table" then
        -- IME WrappedFunction 在场: 由 _wrapImeFunc 负责; 自己的边界(_vt_own)
        -- 已在场: 不重复装(切 zh→en→zh→en 时 IME revert 会把上一次的边界原样写回)
        return
    end
    local class_add = self.addChars
    util.wrapMethod(self, "addChars", function(ib, chars, skip_cb, skip_tc)
        ib._vt_pre_pos = ib.charpos -- 按键前光标(行中插入判定用; IME raw 写直达类方法不经过此处)
        local before_len = #ib.charlist
        class_add(ib, chars, skip_cb, skip_tc)
        local cur = rawget(ib, "addChars")
        if type(cur) == "table" and cur._vt_ime_active then
            ib:refreshInputBar() -- IME 内部 raw 写入(组词/预览), 静默
        else
            ib:_vtKeyEventEnd(chars, before_len)
        end
    end, nil)
    local class_del = self.delChar
    util.wrapMethod(self, "delChar", function(ib)
        class_del(ib)
        ib:refreshInputBar()
    end, nil)
    rawget(self, "addChars")._vt_own = true
    rawget(self, "delChar")._vt_own = true
end

-- IME 在场时包装其 func 为键盘事件边界(仅键盘事件触发 END; IME 内部 raw
-- 编辑走 raw_call 绕过 func, 且途经兜底层时被 _vt_ime_active 静默)
function VTermView:_wrapImeFunc()
    local w = rawget(self, "addChars")
    if type(w) ~= "table" or w._vt_ime_active or w._vt_own then return end
    w._vt_ime_active = true
    local ime_add = w.func
    w.func = function(ib, char, orig_char)
        ib._vt_pre_pos = ib.charpos -- 按键前光标(行中插入判定用)
        local before_len = #ib.charlist
        ime_add(ib, char, orig_char)
        ib:_vtKeyEventEnd(char, before_len)
    end
    local wd = rawget(self, "delChar")
    if type(wd) == "table" and not wd._vt_bound_del then
        wd._vt_bound_del = true
        local ime_del = wd.func
        wd.func = function(ib)
            ime_del(ib)
            ib:refreshInputBar()
        end
    end
end

-- 键盘事件收口的提交判定(详见上方分层注释)
-- 行中插入模型: 光标(charpos)停在已提交行内时, 直通字符按 InputText 语义
-- 插到光标处(同步发 PTY, readline 在其光标处插入, 两端一致);
-- IME 组词只支持行尾 —— 光标在行中时先回拉到已提交行尾再继续组词。
function VTermView:_vtKeyEventEnd(char, before_len)
    local after_len = #self.charlist
    local pre_pos = self._vt_pre_pos
    self._vt_pre_pos = nil
    if after_len <= self._vt_sent then return end
    local ls = self._vt_line_start or 0
    local tail = table.concat(self.charlist, "", self._vt_sent + 1, after_len)
    -- 候选预览未收口(尾字符 ])只该在 zh IME 组词中拦截。无差别拦截曾让
    -- Ctrl+](控制字节 0x1D, vim 跳 tag)和 en 布局的字面 ](shell glob)
    -- 永远发不出去。放行条件: 非 IME 布局, 或 Ctrl 挂起(按控制字节处理)。
    local w = rawget(self, "addChars")
    local ime_active = type(w) == "table" and w._vt_ime_active
    if tail:sub(-1) == "]" and ime_active and not self._vt_ctrl_pending then
        return end -- 候选预览未收口,组词中
    -- 已提交行长(行内坐标): 当前行的已提交部分 = charlist[ls+1.._vt_sent]
    local clin = self._vt_sent - ls
    if after_len > before_len then
        local appended = table.concat(self.charlist, "", before_len + 1, after_len)
        -- 回车 \n→\r 映射: 对账前规范化(addChars 入口已把 \n 转成 \r,
        -- 差分比较必须同步, 否则回车会被误判成 IME 组词写入而静默)
        local norm_c = char and char:gsub("\r", "\n") or char
        local norm_a = appended:gsub("\r", "\n")
        if norm_a ~= norm_c then
            -- IME 组词写入: 光标在行中先回拉已提交行尾(组词区只认行尾)
            local pos = pre_pos or clin + 1
            if pos <= clin then
                self:sendBytes(string.rep("\27[C", clin + 1 - pos))
                self.charpos = clin + 1
            end
            return
        end
        -- 直通字符 + 光标在已提交行内 → 真行中插入
        local pos = pre_pos or clin + 1
        if pos >= 1 and pos <= clin then
            local ch = table.remove(self.charlist) -- 摘掉刚追加在尾部的副本
            table.insert(self.charlist, ls + pos, ch)
            self._vt_sent = after_len -- 整行(含新字符)都已提交
            self.charpos = pos + 1
            self:_ctrlWrite(ch)       -- shell 在其光标处插入, 与本地一致
            if ch:find("\r", 1, true) then
                self._vt_bar_line = nil    -- 回车: 本行结束
                self._vt_line_start = after_len
                self.charpos = 1
            else
                local bchars = util.splitToChars(self._vt_bar_line or "")
                table.insert(bchars, pos, ch)
                self._vt_bar_line = table.concat(bchars)
            end
            self:refreshInputBar()
            return
        end
    end
    -- 行尾路径(IME 提交/行尾追加): 光标停在行中时先回拉
    --
    -- 但"净减"不等于提交: 继续打拼音/切候选时, 新候选串可能比上一条短
    -- (单候选提示没有方括号), 这只是组词中间态。误当提交会把候选文字发给
    -- 终端, 随后 IME 删预览又按"已提交字符"补发退格(vim 里表现为前一个词
    -- 被吃掉)。字母与候选切换键只会刷新候选, 一律不发送。
    local function is_compose_key(c)
        if not c or #c ~= 1 then return false end
        local b = c:byte()
        return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or c == "→" or c == "←"
    end
    -- 只在 IME 布局生效: EN 直通布局里字母就是真实输入, 逐键必须立刻发
    -- (曾误拦 → 英文打字整串不显示, 只有按空格/回车才吐出来)
    local wadd = rawget(self, "addChars")
    if type(wadd) == "table" and wadd._vt_ime_active and is_compose_key(char) then
        return
    end
    local pos = pre_pos or clin + 1
    if pos <= clin then
        self:sendBytes(string.rep("\27[C", clin + 1 - pos))
        self.charpos = clin + 1
    end
    self._vt_sent = after_len
    if tail:find("\n", 1, true) or tail:find("\r", 1, true) then
        self._vt_bar_line = nil      -- 回车: 本行结束, 清空中文镜像
        self._vt_line_start = after_len -- 新行起点
        self.charpos = 1             -- 新行行首(防上一事件残留行中位置误判插入)
    else
        self._vt_bar_line = (self._vt_bar_line or "") .. tail
        self.charpos = after_len - ls + 1 -- 行尾追加: 光标复位到行尾(同上)
    end
    -- 逐字符发送: 真机探针实证整串多字节一次 write 时, 真机 bash(系统
    -- busybox 1.28 的 readline, 非 UTF-8 locale)会把首字符拆成坏字节回显
    -- (嗯→å??); 逐字符 write+回显时 readline 整行重印、字节原样(真实
    -- 终端逐键等效)。_ctrlWrite 单字符粒度仍受 Ctrl 修饰语义约束。
    for _, ch in ipairs(util.splitToChars(tail)) do
        self:_ctrlWrite(ch)
    end
end

-- 合并式提交已由事件边界(_vtKeyEventEnd)取代, 见 _installInputBoundary 注释

-- 刷新候选字条区域: 从网格末行下沿到分配区底(=键盘上沿), 含细线与候选字;
-- 条带内的旧文字必须整块重绘, 否则局部刷新会留下上一帧的字形残影
function VTermView:refreshInputBar()
    if (self.bar_h or 0) <= 0 then return end -- 直通布局无条带(组词不用)
    if not self.dimen then return end
    local off = self._inner_off
    local avail_h = self.avail_rows_h or (self.rows * self.cell_h)
    local region = Geom:new{
        x = self.dimen.x + off,
        y = self.dimen.y + off + self.rows * self.cell_h,
        w = self.cols * self.cell_w,
        h = (avail_h + self.bar_h + off) - self.rows * self.cell_h,
    }
    self:queueDirty(region)
end

-- Ctrl 修饰 + PTY 写入
function VTermView:_ctrlWrite(data)
    if self._vt_ctrl_pending then
        -- 标准 C0 控制字符变换: Ctrl+<chr(0x40..0x5F)> = chr(code-0x40)。
        -- 覆盖 A-Z(既有)与 @ [ \ ] ^ _(Ctrl+]=0x1D 是 vim 帮助跳 tag 的
        -- 标准键); 小写字母同变换; Space→NUL(0x00); ?→DEL(0x7F)。
        -- 其余(ESC 序列/数字/符号)不变换, 首字符之外原样透传。
        local b = data:sub(1, 1):byte()
        if b then
            local ctrl
            if b >= 0x61 and b <= 0x7A then
                ctrl = b - 0x60
            elseif b >= 0x40 and b <= 0x5F then
                ctrl = b - 0x40
            elseif b == 0x20 then
                ctrl = 0x00
            elseif b == 0x3F then
                ctrl = 0x7F
            end
            if ctrl then
                data = string.char(ctrl) .. data:sub(2)
            end
        end
        self._vt_ctrl_pending = false
        -- Ctrl 是一次性修饰: 用掉后通知按钮把下划线撤掉
        if self._vt_on_ctrl_used then self:_vt_on_ctrl_used() end
    end
    if self._vt_write then self._vt_write(data) end
end

-- 按钮行/方向键等直接发送通道
function VTermView:sendBytes(seq)
    if not seq or #seq == 0 then return end
    self:refreshInputBar()
    self:_ctrlWrite(seq)
end

-- 长按终端区:
-- 1. 触摸鼠标使能 + Ctrl 挂起 + 在屏幕网格上长按: 定义为按下鼠标右键 (btn = 2)。
--    保持按住状态 (_vt_mouse_down, _vt_mouse_btn = 2), 支持随手指移动拖拽选区 (btn = 34),
--    手指抬起时释放 (btn = 2)。
-- 2. 其余场景: 彻底禁用 InputText 的剪贴板面板(复制/粘贴/全选), 吞掉 hold + 置 _hold_handled
--    避免模态弹窗打断终端手势。
function VTermView:onHoldTextBox(arg, ges)
    return self:holdTextBox(arg, ges)
end

function VTermView:holdTextBox(arg, ges)
    self._hold_handled = true
    local ev = (type(ges) == "table" and ges.pos and ges)
        or (type(arg) == "table" and arg.pos and arg)
        or ges or arg
    local pos = ev and ev.pos
    if self:_mouseActive() and self._vt_ctrl_pending and pos and not self._vt_collapsed then
        local r = self:_gridRegion()
        if r:contains(pos) then
            self:_ensureLive()
            local cell = self:_mouseCell(pos)
            self._vt_mouse_down = cell
            self._vt_mouse_btn = 2
            self:_mouseSend(2, true, cell) -- 右键按下 (SGR: \27[<2;col;rowM)
            self._vt_ctrl_pending = false
            if self._vt_on_ctrl_used then self:_vt_on_ctrl_used() end
            return true
        end
    end
    return true
end

function VTermView:onHoldReleaseTextBox(arg, ges)
    if self:_mouseActive() and self._vt_mouse_down then
        local btn = self._vt_mouse_btn or 0
        self:_mouseSend(btn, false, self._vt_mouse_down)
        self._vt_mouse_down = nil
        self._vt_mouse_btn = nil
        return true
    end
    return true
end

-- 类方法 = 纯草稿缓冲编辑(键盘直通与 IME 内部 raw 调用都落在这里):
-- 绝不直接发送, 提交统一由事件边界(_vtKeyEventEnd)按差分判定
function VTermView:addChars(chars, skip_callback, skip_table_concat)
    if not chars or #chars == 0 then return end
    -- 终端 Enter 语义: 软键盘回车发 \n(LF), 但 raw 模式的 TUI(pi agent 等)
    -- 只认 \r(CR) 为"发送"、\n 是换行。统一改发 \r: canonical shell 由 tty
    -- 的 icrnl 转回 \n, readline 两者皆收, 三种场景全兼容。
    chars = chars:gsub("\n", "\r")
    self:_bufAppend(chars)
    self:refreshInputBar()
end

function VTermView:delChar()
    local n = #self.charlist
    if n == 0 then
        -- 草稿缓冲为空: 方向键调出的历史命令等内容在 shell 的 readline 行上,
        -- 不经过草稿缓冲(方向键直接发 PTY 字节)——此时 ⌫ 必须盲发真实退格,
        -- 由 readline/程序自行处理, 否则历史命令无法逐字符删除。
        self:_ctrlWrite("\127")
        return
    end
    local ls = self._vt_line_start or 0
    local clin = self._vt_sent - ls -- 当前行已提交长度
    local pos = self.charpos or (n - ls + 1)
    -- 草稿区(IME 组词, 只存在于 charlist 尾部): 只删本地草稿不发,
    -- 光标回到新末尾 —— 组词编辑不触碰已提交行
    if pos > clin + 1 then
        table.remove(self.charlist)
        self.charpos = #self.charlist - ls + 1
        self:refreshInputBar()
        return
    end
    if pos <= 1 then
        -- 行首/本行模型为空(典型: ↑ 调出的历史命令不在模型里): 盲发退格,
        -- 由 readline/lineedit 自行处理 —— 否则历史命令无法逐字删除
        self:_ctrlWrite("\127")
        return
    end
    local gidx = ls + pos - 1 -- 行内下标 → charlist 全局下标
    if gidx < 1 or gidx > n then return end
    local ch = table.remove(self.charlist, gidx)
    self.charpos = pos - 1
    if gidx <= self._vt_sent then
        -- 删已提交字符 = 真实终端退格; 输入条镜像按行内位置同步
        self._vt_sent = self._vt_sent - 1
        -- 不变式 sent ≥ ls(行起点不能越过提交前缀): 历史回溯等脏状态下
        -- ⌫ 可能把 sent 减穿 ls, 不钳制则后续 maxpos=0 光标错乱
        if self._vt_sent < ls then self._vt_line_start = self._vt_sent end
        -- 删除语义分派: raw 模式且不在 shell 提示符行 = 全屏编辑器。
        -- 退格粒度按编辑器实测能力: main 在本地会话首次插入 CJK 时记录网格
        -- 光标步进 — 宽字符 vim = 2 列(1 个 \x7f 删 1 字), 字节级 busybox vi
        -- = 3 列(需 #字节 个 \x7f 删净)。未探测(纯 ASCII 会话)时维持 #字节
        -- 粒度(保守: shell 行/canonical 读仍走 1 个分支, 不受影响)。
        local byte_level = self.pty and self.pty.byte_level_editor
        if byte_level == nil then byte_level = true end
        if self._vt_local and self.pty and not self.pty:isCanonical()
            and not self.pty:lineActive() then
            if byte_level then
                self:_ctrlWrite(string.rep("\127", #ch))
            else
                self:_ctrlWrite("\127")
            end
        else
            self:_ctrlWrite("\127")
        end
        local bchars = util.splitToChars(self._vt_bar_line or "")
        if pos <= #bchars + 1 then table.remove(bchars, pos - 1) end
        self._vt_bar_line = table.concat(bchars)
    end
    self:refreshInputBar()
end

function VTermView:delWord(left_to_cursor)
    self:sendBytes("\23") -- Ctrl+W (Lua 转义是十进制: 23 = 0x17)
end

function VTermView:delToStartOfLine()
    -- Ctrl-U: shell 删"行首到光标"; 视图模型同步(影子行合成的行内容依据)
    local ls = self._vt_line_start or 0
    local clin = self._vt_sent - ls
    local pos = math.max(1, math.min(self.charpos or (clin + 1), clin + 1))
    for _ = 1, pos - 1 do
        table.remove(self.charlist, ls + 1)
    end
    self._vt_sent = math.max(ls, self._vt_sent - (pos - 1))
    if self._vt_bar_line then
        local bchars = util.splitToChars(self._vt_bar_line)
        for _ = 1, math.min(pos - 1, #bchars) do
            table.remove(bchars, 1)
        end
        self._vt_bar_line = #bchars > 0 and table.concat(bchars) or nil
    end
    self.charpos = 1
    self:sendBytes("\21") -- Ctrl+U (21 = 0x15; 原先写成 \025=25 实际发的是 Ctrl-Y)
end

-- 行中光标模型: ←/→ 同步移动本地 charpos(行内相对)与 shell readline 光标。
-- 有未提交草稿时 shell 行终点 = 已提交前缀末尾, 光标钳制于此。
function VTermView:leftChar(skip_callback)
    local ls = self._vt_line_start or 0
    local n, sent = #self.charlist, self._vt_sent
    local maxpos = math.max(1, (n > sent) and (sent - ls + 1) or (n - ls + 1))
    local pos = math.min(self.charpos or maxpos, maxpos)
    self.charpos = math.max(1, pos - 1)
    self:sendBytes("\27[D")
end

function VTermView:rightChar(skip_callback)
    local ls = self._vt_line_start or 0
    local n, sent = #self.charlist, self._vt_sent
    local maxpos = math.max(1, (n > sent) and (sent - ls + 1) or (n - ls + 1))
    local pos = math.min(self.charpos or maxpos, maxpos)
    self.charpos = math.min(pos + 1, maxpos)
    self:sendBytes("\27[C")
end

function VTermView:upLine(skip_callback)
    self.charpos = nil -- 换历史行: 行内容整体被 shell 替换, 光标模型重置
    self:sendBytes("\27[A")
end

function VTermView:downLine(skip_callback)
    self.charpos = nil
    self:sendBytes("\27[B")
end

function VTermView:goToStartOfLine(skip_callback)
    self.charpos = 1 -- 行首键同步光标模型(有草稿时 readline 也在提交行内移动)
    self:sendBytes("\27[H")
end

function VTermView:goToEndOfLine(skip_callback)
    local ls = self._vt_line_start or 0
    local n, sent = #self.charlist, self._vt_sent
    self.charpos = (n > sent) and (sent - ls + 1) or (n - ls + 1)
    self:sendBytes("\27[F")
end

function VTermView:scrollUp(skip_callback, lines)
    if self._vt_sb_mode and self._vt_sb then
        if self._vt_sb:scrollUp(lines or 1) > 0 then self:queueDirty(self:_gridRegion()) end
        return
    end
    self:sendBytes("\27[5~") -- PageUp
end

function VTermView:scrollDown(skip_callback, lines)
    if self._vt_sb_mode and self._vt_sb then
        if self._vt_sb:scrollDown(lines or 1) > 0 then self:queueDirty(self:_gridRegion()) end
        if not self._vt_sb:isScrolling() then self:queueDirty(self:_gridRegion()) end
        return
    end
    self:sendBytes("\27[6~") -- PageDown
end

-- 网格整体区域(翻看/手势刷新用)
function VTermView:_gridRegion()
    local off = self._inner_off
    return Geom:new{
        x = self.dimen.x + off,
        y = self.dimen.y + off,
        w = self.cols * self.cell_w,
        h = self.rows * self.cell_h,
    }
end

-- ==================== 方向手势开关 ====================

-- 触摸手势实测记录(诊断用): 插件目录存在 geslog.on 即追加写 ges.log
function VTermView:_gesLog(s)
    local p = self._vt_plugin_path
    if not p then return end
    local f = io.open(p .. "/geslog.on", "r")
    if not f then return end
    f:close()
    local g = io.open(p .. "/ges.log", "a")
    if g then
        g:write(os.date("%H:%M:%S"), " ", s, "\n")
        g:close()
    end
end

-- 开启后: 网格内左/右/上/下滑 = 方向键; 滑完按住不放 = 连续重复
function VTermView:setArrowGestures(enable)
    self._vt_arrows = enable and true or false
    if not self.ges_events then self.ges_events = {} end
    -- ⚠️ 内置 GestureRange 只按终点 pos 判定: 向上滑终点滑出网格顶部(标题区)、
    -- 向下滑终点落进输入框/软键盘 → 手势全丢, ↑/↓ 最常用方向"完全无效"。
    -- 自定义 matcher: 起点或终点任一在网格即命中(起点判定是主力)。
    -- (终点落在 VirtualKey 上时 VK 仍会抢先消费, 那是 window 栈序, 无解。)
    -- ⇆ 关闭分支也要用它注册 swipe(方向键/翻页), 故定义在分支外。
    local function grid_matcher(ges_name)
        return {
            ges = ges_name,
            match = function(_, gs)
                -- ⚠️ 必须先按事件名过滤(内置 GestureRange:match 的第一职责):
                -- 漏掉会把 tap 等其它手势"吃掉"——⇆ 开启后网格区触摸全失灵。
                local hit = false
                local pos_s, start_s = "nil", "nil"
                if gs.ges == ges_name then
                    local r = self.dimen and self:_gridRegion()
                    if r then
                        if gs.pos and r:contains(gs.pos) then hit = true end
                        if not hit and gs.start_pos and r:contains(gs.start_pos) then hit = true end
                        if not hit and gs.end_pos and r:contains(gs.end_pos) then hit = true end
                    end
                    if gs.pos then pos_s = gs.pos.x .. "," .. gs.pos.y end
                    if gs.start_pos then start_s = gs.start_pos.x .. "," .. gs.start_pos.y end
                end
                self:_gesLog(string.format("match want=%s got=%s pos=%s start=%s hit=%s",
                    ges_name, tostring(gs.ges), pos_s, start_s, tostring(hit)))
                return hit
            end,
        }
    end
    -- release 类事件只按名字匹配, 不做网格判定: 终止信号不是方向载体,
    -- 下滑收尾时手指常已落在网格外(键盘区), 挂网格 matcher 会被丢弃 →
    -- 状态机没人叫停 → 1 秒后误连发(真机 SEND 洪流实证 2026-11-08)。
    local function release_matcher(ges_name)
        return { ges = ges_name, match = function(_, gs) return gs.ges == ges_name end }
    end
    if self._vt_arrows then
        self.ges_events.VTermSwipe = { grid_matcher("swipe") }
        self.ges_events.VTermHoldPan = { grid_matcher("hold_pan") }
        -- 单指松手事件名是 hold_release(hold_pan 抬指时必发);
        -- hold_pan_release 是双指变体(two_finger_hold_pan)的释放名, 用错会松手不停
        self.ges_events.VTermHoldPanRelease = { release_matcher("hold_release") }
        -- 慢速拖动 = pan(快速甩动才是 swipe): 墨水屏上用户滑动普遍偏慢,
        -- 不注册 pan 则慢滑完全无反应。pan 是连续事件, 走 hold_pan 同款节流。
        self.ges_events.VTermPan = { grid_matcher("pan") }
        self.ges_events.VTermPanRelease = { release_matcher("pan_release") }
        -- touch(手指按下, 不限位置): 任何新触摸=旧滑动会话死亡——滑完去键盘打字,
        -- 停顿计时不作废会在打字中到期误连发(touch 是手势结束的兜底信号,
        -- 快速抬起的 pan 流可能既没有 pan_release 也没有 swipe)。
        self.ges_events.VTermTouch = {
            { ges = "touch", match = function(_, gs) return gs.ges == "touch" end },
        }
    else
        -- ⇆ 关闭: 一次拖动 = 一发(⇕关=↑/↓, ⇕开=远端 PgUp/PgDn, 见 _pageAction)。
        -- 必须同时注册 pan: 墨水屏上慢速拖动普遍被判成 pan(只有快甩才是 swipe),
        -- 只留 swipe 会让"滑了没反应"; pan 流与收尾 swipe 由 _vt_page_dir 去重。
        self:_stopArrowRepeat()
        self._vt_page_dir = nil
        self.ges_events.VTermSwipe = { grid_matcher("swipe") }
        self.ges_events.VTermPan = { grid_matcher("pan") }
        self.ges_events.VTermPanRelease = { release_matcher("pan_release") }
        self.ges_events.VTermHoldPan = { grid_matcher("hold_pan") }
        self.ges_events.VTermHoldPanRelease = { release_matcher("hold_release") }
        self.ges_events.VTermTouch = {
            { ges = "touch", match = function(_, gs) return gs.ges == "touch" end },
        }
    end
end

function VTermView:_arrowSeq(direction)
    -- ⚠️ GestureDetector 的方向词是罗盘制(south/north/east/west, 可带对角如
    -- south_east)——真机 ges.log 实证 3002 次 pan 的方向全是罗盘词, 一个
    -- down/up/left/right 都没有; 只认后者则方向键永远发不出去。
    if not direction then return nil end
    local map = {
        north = "\27[A", south = "\27[B", east = "\27[C", west = "\27[D",
        up = "\27[A", down = "\27[B", right = "\27[C", left = "\27[D",
    }
    if map[direction] then return map[direction] end
    -- 对角(northeast/southwest...)取主轴, 垂直轴优先(终端 ↑/↓ 最常用)
    for _, k in ipairs({ "north", "south", "east", "west", "up", "down", "right", "left" }) do
        if direction:find(k, 1, true) then return map[k] end
    end
    return nil
end

-- 翻看态(本地滚动中)发方向键/翻页键前必须滚回实时帧: 否则 shell 的响应被
-- 翻看帧遮住, 手势看起来毫无反应("⇆/⇕ 开启后终端无响应"的真身)。
-- 不依赖 _vt_sb_mode: ⇕ 在翻看中被人为关掉时同样需要回底。
function VTermView:_ensureLive()
    if self._vt_sb and self._vt_sb:isScrolling() then
        while self._vt_sb:scrollDown(1) > 0 do end
        self:queueDirty(self:_gridRegion())
    end
end

-- Shift 挂起状态判据: 软键盘展开时跟随 keyboard.shiftmode, 键盘收起/全屏时保持 _vt_shift_mode 缓存
function VTermView:_hasShift()
    if not self._vt_collapsed and self.keyboard then
        self._vt_shift_mode = self.keyboard.shiftmode and true or false
    end
    return self._vt_shift_mode or (self.keyboard and self.keyboard.shiftmode) or false
end

-- ⇆(方向手势)关闭时, 上下滑 = PuTTY 式三级阶梯(定稿):
--   ⇆关 + ⇕关 → ↑/↓ 方向键(逐行);
--   ⇆关 + ⇕开 → 远端 PageUp/PageDown(\27[5~/6~);
--   ⇆开 + ⇕开 → 本地历史翻页一屏(等效 Shift+PageUp/PageDown, 见 _vtAction);
--   ⇆开 + ⇕关 → 带连发的方向手势(见 _vtAction)。
-- 返回闭包, nil=该方向无动作。
function VTermView:_pageAction(direction)
    if not direction then return nil end
    if self._vt_arrows then return nil end -- ⇆ 开启: 手势归 _vtAction
    local is_up = direction:find("north", 1, true) or direction:find("up", 1, true)
    local is_down = direction:find("south", 1, true) or direction:find("down", 1, true)
    if not (is_up or is_down) then return nil end
    if self._vt_sb_mode then
        -- ⇕ 开: 远端翻页键(PuTTY 的 PageUp/PageDown)。软键盘 Shift 挂起时
        -- 发修饰变体(Shift+PgUp/Dn = \27[5;2~/\27[6;2~), 与 Ctrl+键同理
        -- (修饰与输入组合); Shift 不在此消耗——下一次打字由键盘自身消化。
        return function()
            self:_ensureLive()
            local mod = ""
            if self:_hasShift() then mod = ";2" end
            self:sendBytes(is_up and ("\27[5" .. mod .. "~") or ("\27[6" .. mod .. "~"))
        end
    end
    -- 二者皆关: 方向键逐行(经 upLine/downLine 维护行中光标模型)
    return function()
        self:_ensureLive()
        if is_up then self:upLine() else self:downLine() end
    end
end

-- ⇆ 关时的 pan 入口: 墨水屏慢速拖动走 pan 流(不是 swipe), 一次拖动只发一发。
-- `_vt_page_dir` 同时给收尾的 swipe 去重(快甩时 pan 流与 swipe 都会到)。
function VTermView:_pagePan(ges)
    local dir = ges and ges.direction
    local act = self:_pageAction(dir)
    if not act then return false end -- 水平/无方向: 不消费
    if self._vt_page_dir then return true end
    self._vt_page_dir = dir
    act()
    return true
end

-- ⇕(sb_mode)开启时上下滑=本地翻页一屏(等效 PageUp/PageDown, 不动 PTY);
-- 其余方向发方向键(发前滚回实时帧)。返回闭包, nil=该方向无动作。
-- swipe/pan/连发三处共用本解析, 保证"上下滑动逻辑与左右滑动一致"。
function VTermView:_vtAction(direction)
    if not direction then return nil end
    local is_up = direction:find("north", 1, true) or direction:find("up", 1, true)
    local is_down = direction:find("south", 1, true) or direction:find("down", 1, true)
    if is_up or is_down then
        -- 左右滑动使能后: Shift 挂起 + 上/下滑 = PageUp/PageDown(\27[5~ / \27[6~)
        if self:_hasShift() then
            local seq = is_up and "\27[5~" or "\27[6~"
            return function()
                self:_ensureLive()
                self:sendBytes(seq)
            end
        end
        if self._vt_sb_mode and self._vt_sb then
            local page = math.max(1, self.rows - 1) -- 少留一行衔接上下文
            return function()
                if is_up then self:scrollUp(nil, page) else self:scrollDown(nil, page) end
            end
        end
    end
    local seq = self:_arrowSeq(direction)
    if seq then
        -- 必须经 leftChar/rightChar/upLine/downLine: 它们维护行中光标模型
        -- (charpos), 直发裸序列会绕过模型导致后续插入错位
        return function()
            self:_ensureLive()
            if seq == "\27[D" then self:leftChar()
            elseif seq == "\27[C" then self:rightChar()
            elseif seq == "\27[A" then self:upLine()
            else self:downLine() end
        end
    end
    return nil
end

function VTermView:onVTermSwipe(_, ges)
    self:_gesLog("SWIPE dir=" .. tostring(ges.direction) .. " arrows=" .. tostring(self._vt_arrows))
    -- 鼠标模式(⇆ 关): 拖动未完=抬起收尾; 否则上下滑=滚轮(vim 滚屏)。
    -- ⇆ 开: 滑动归普通键(方向/翻页), 不做鼠标
    if self:_mouseActive() and not self._vt_arrows then
        if self._vt_mouse_down then
            self:_mouseSend(0, false, self._vt_mouse_down)
            self._vt_mouse_down = nil
            return true
        end
        local d = ges.direction or ""
        local cell = ges.pos and self:_mouseCell(ges.pos)
        if d:find("north", 1, true) then
            for _ = 1, 3 do self:_mouseSend(64, true, cell) end -- 滚轮上×3
            return true
        elseif d:find("south", 1, true) then
            for _ = 1, 3 do self:_mouseSend(65, true, cell) end -- 滚轮下×3
            return true
        end
        return true -- 鼠标模式下左右滑不做事
    end
    -- ⇆ 关闭时上下滑=↑/↓(⇕关) 或 PgUp/PgDn(⇕开), 一次滑动一发, 其余方向不消费。
    -- pan 流(慢速拖动)可能已经发过本手势的一发: _vt_page_dir 去重, 收尾不补发。
    if not self._vt_arrows then
        local act = self:_pageAction(ges.direction)
        local already = self._vt_page_dir ~= nil
        if act and not already then act() end
        self._vt_page_dir = nil -- 手势结束, 下次拖动重新计
        return act ~= nil or already
    end
    -- swipe 的 pos 是滑动起点: pan 流已发过键(方向状态在)就不再补发,
    -- 否则一次滑动方向键双发(违反"一次滑动一发")。
    if not self._vt_arrow_dir then
        local act = self:_vtAction(ges.direction)
        if act then act() end
    end
    -- swipe = 手指已抬起(手势结束): 作废 pan 流遗留的停顿计时——
    -- 否则抬手 1s 后连发启动, 用户在键盘上按删除键时终端误连发。
    self:_stopArrowRepeat()
    self._vt_last_pan_pos = nil -- 与 release 对齐: 位置基准清零
    return true
end

function VTermView:onVTermHoldPan(_, ges)
    self:_gesLog("HOLDPAN dir=" .. tostring(ges.direction) .. " cur=" .. tostring(self._vt_arrow_dir))
    -- 连发存活判据的时间源: 只要 pan 事件还在来(含静止噪声)就证明手指还在。
    -- ⚠️fts 微秒值, 时钟回调里与 time.s() 比较
    self._vt_last_ges_fts = time.now()
    -- 鼠标模式(⇆ 关): 按住移动 = button-1 motion(拖动选区/滚动)。首个
    -- hold_pan 处建立按下状态(touch 无 pos, _vt_mouse_down 只能在这里初始化)
    if self:_mouseActive() and not self._vt_arrows and ges.pos and not self._vt_collapsed then
        local p = ges.pos
        local grid = self:_gridRegion()
        if p and grid and grid:contains(p) and self.pty.mouse_drag then
            local cell = self:_mouseCell(p)
            if not self._vt_mouse_down then
                self._vt_mouse_down = cell
                self._vt_mouse_btn = 0
                self:_mouseSend(0, true, cell)
            end
            if cell.col ~= self._vt_mouse_down.col or cell.row ~= self._vt_mouse_down.row then
                local btn = self._vt_mouse_btn or 0
                self:_mouseSend(32 + btn, true, cell) -- 左键拖动=32, 右键拖动=34!
                self._vt_mouse_down = cell
            end
        end
        return true
    end
    if not self._vt_arrows then
        -- ⇆ 关: 慢速拖动也只发一发(↑/↓ 或 PgUp/PgDn), 不做连发/换向状态机
        return self:_pagePan(ges)
    end
    local dir = ges.direction
    local act = dir and self:_vtAction(dir)
    if not act then return true end
    -- 位置稳定判定: 与上次记录相距 < STABLE_PX 视为手指停住(触摸噪声/手抖——
    -- 真机 ges.log 实证按住不动时 pos 每帧仍微动 1~4px, pan 事件流永不静默,
    -- 停顿计时会被无限重置)。停住不重置 1s 计时; 真移动才换向判定+重置。
    local p = ges.pos
    -- 手指滑出网格区(拖去软键盘/标题) → 终止方向手势状态机:
    -- 否则停在键盘上按删除键时, 1s 停顿计时到期会误触发连发,
    -- 且拖进键盘的动作不是 tap, 删除键会失效。
    local grid = self:_gridRegion()
    if p and grid and not grid:contains(p) then
        self:_gesLog("OUT-OF-GRID stop pos=" .. p.x .. "," .. p.y)
        self:_stopArrowRepeat()
        return true
    end

    -- 连发已在进行中: 只要手指在网格内且未明确换向, 忽略一切细微抖动, 保持连续触发
    if self._vt_repeat_task then
        if dir and dir ~= self._vt_arrow_dir then
            -- 明确换向: 立即发一次新方向, 并在新方向重启连发
            self:_stopArrowRepeat()
            self._vt_arrow_dir = dir
            self._vt_pan_acc = 0
            self._vt_last_send_t = time.now()
            act()
            self._vt_still_since = time.now()
            self:_startRepeatClock()
        end
        if p then self._vt_last_pan_pos = { x = p.x, y = p.y } end
        return true
    end

    local moved = true
    if p and self._vt_last_pan_pos then
        local dx = p.x - self._vt_last_pan_pos.x
        local dy = p.y - self._vt_last_pan_pos.y
        local d2 = dx * dx + dy * dy
        moved = d2 >= self.STABLE_PX * self.STABLE_PX
        -- 位移累加: 手指持续移动时只累积不触发(防连续滑动刷屏/误触),
        -- 累计够 SWIPE_UNIT 像素才发一发并清零
        if moved then
            self._vt_pan_acc = (self._vt_pan_acc or 0) + math.sqrt(d2)
        end
    end
    if p then self._vt_last_pan_pos = { x = p.x, y = p.y } end
    if moved then
        if dir ~= self._vt_arrow_dir then
            -- 换向: 立即发一次(用户明确改变方向), 累加器清零
            self:_stopArrowRepeat()
            self._vt_arrow_dir = dir
            self._vt_pan_acc = 0
            self._vt_last_send_t = time.now()
            act()
        elseif (self._vt_pan_acc or 0) >= self.SWIPE_UNIT then
            -- 同向持续拖动累计够一段距离: 发一发, 清零继续累积
            self._vt_pan_acc = 0
            self._vt_last_send_t = time.now()
            act()
        end
        -- 真移动: 停连发时钟, 停顿计时从这里重新起算
        self._vt_still_since = nil
        self:_stopRepeatClock()
    else
        -- 停住: 只负责"起算停住起点", 真正的连发交给固定节拍定时器
        -- (`_startRepeatClock`)。不在这里每事件发键——事件到达频率不均匀,
        -- 由它驱动会导致连发忽快忽慢、手抖大位移还会额外跳格(用户实测)。
        if not self._vt_still_since and not self._vt_repeat_task then
            self._vt_still_since = time.now()
            self:_startRepeatClock()
        end
    end
    return true
end

-- 固定节拍连发: 停住满 REPEAT_DELAY 秒后, 每 REPEAT_PERIOD 秒发一发,
-- 直到 `_stopRepeatClock()`(抬起/换向/移动/滑出网格)。
-- ⚠️⚠️time.now() 返回的是 fts 定点**微秒**值, 不是普通秒! 所有秒数必须经
-- time.s() 换算再比较/相加; 普通数字直接当 fts 用 = "1.0"=1 微秒 → 判据
-- 恒真 → 暴涨连发(设备实测 2 秒 200+ 发)。scheduleIn 收的则是**秒**(float)。
function VTermView:_startRepeatClock()
    if self._vt_repeat_task then return end
    -- 记录连发方向的单位向量: 停住期间噪声位移用它判"是否转向"
    local seq = self:_arrowSeq(self._vt_arrow_dir)
    self._vt_rep_dir_v = seq == "\27[A" and { x = 0, y = -1 }
        or seq == "\27[B" and { x = 0, y = 1 }
        or seq == "\27[C" and { x = 1, y = 0 }
        or { x = -1, y = 0 }
    local base = self._vt_still_since or time.now()
    -- 时钟实例代号: 只有当前代号的任务才允许继续排下一拍。
    -- ⚠️不能只靠 _vt_repeat_task ~= nil 互斥——回调里先置 nil 再重排,
    -- 中间若来 pan 噪声事件会再启一个时钟 → 多时钟并行。
    local tok = (self._vt_repeat_tok or 0) + 1
    self._vt_repeat_tok = tok
    local delay_fts = time.s(self.REPEAT_DELAY)
    local period_fts = time.s(self.REPEAT_PERIOD)
    local fn
    fn = function()
        if self._vt_repeat_tok ~= tok then return end -- 已被停止/取代
        if not self._vt_arrows or not self._vt_arrow_dir then return end

        -- 抬手检测(首行守卫): 真机抬手后 release 事件可能整体丢失,
        -- 静默超过 0.5s 说明手指已不在屏幕上, 立即自杀叫停连发
        local since_ges = time.now() - (self._vt_last_ges_fts or 0)
        if since_ges > time.s(0.5) then
            self:_stopArrowRepeat()
            return
        end

        local elapsed = time.now() - base
        if elapsed < delay_fts then
            self._vt_repeat_task = fn
            UIManager:scheduleIn(time.to_s(delay_fts - elapsed), fn)
            return
        end
        local dir = self._vt_arrow_dir
        -- 硬节流: 无论存在几个时钟实例, 距上次真实发送 < 周期×0.8 一律不发
        -- (代字号防线失效时的最后保险, 保证设备实测速率不超 REPEAT_PERIOD)
        local since_send = time.now() - (self._vt_last_send_t or time.huge)
        if since_send < period_fts * 0.8 then
            self._vt_repeat_task = fn
            UIManager:scheduleIn(self.REPEAT_PERIOD, fn)
            return
        end
        local rep = self:_vtAction(dir)
        if rep then rep() end
        self._vt_last_send_t = time.now()
        -- 下一拍按"起点 + n×周期"对齐, 漂移不累积
        self._vt_repeat_n = (self._vt_repeat_n or 0) + 1
        local wait_fts = base + delay_fts
            + self._vt_repeat_n * period_fts - time.now()
        if wait_fts < time.us(5000) then wait_fts = time.us(5000) end
        self._vt_repeat_task = fn
        UIManager:scheduleIn(time.to_s(wait_fts), fn)
    end
    self._vt_repeat_task = fn
    UIManager:scheduleIn(self.REPEAT_DELAY, fn)
end

function VTermView:_stopRepeatClock()
    self._vt_repeat_n = 0
    self._vt_repeat_tok = (self._vt_repeat_tok or 0) + 1 -- 作废在跑的所有时钟
    if self._vt_repeat_task then
        UIManager:unschedule(self._vt_repeat_task)
        self._vt_repeat_task = nil
    end
end

function VTermView:onVTermHoldPanRelease(_, ges)
    self:_gesLog("RELEASE")
    -- 鼠标模式: 拖动结束 = 抬起
    if self:_mouseActive() and self._vt_mouse_down then
        local btn = self._vt_mouse_btn or 0
        self:_mouseSend(btn, false, self._vt_mouse_down)
        self._vt_mouse_down = nil
        self._vt_mouse_btn = nil
        return true
    end
    self:_stopArrowRepeat()
    self._vt_page_dir = nil -- ⇆关: 手势结束, 下次拖动重新计
    self._vt_last_pan_pos = nil -- 位置基准清零, 下次拖动重新建立
    return true
end

-- touch(手指按下, 任何位置): 旧滑动会话立即死亡——作废停顿计时/连发/方向。
-- 不消费(return false), touch 继续正常路由给键盘等 widget。
function VTermView:onVTermTouch(_, ges)
    self._vt_page_dir = nil -- 新触摸=上一次拖动会话结束(⇆关翻页去重标记)
    -- 鼠标模式(⇆ 关): 网格内按下 = button-1 press(vim 收到即跟随光标)。
    -- ⇆ 开: 不发 press——滑动已让位普通键, 按下会残留拖拽态
    if self:_mouseActive() and not self._vt_arrows and not self._vt_collapsed and ges.pos then
        local r = self:_gridRegion()
        if r:contains(ges.pos) then
            self:_ensureLive()
            self._vt_mouse_down = self:_mouseCell(ges.pos)
            self:_mouseSend(0, true, self._vt_mouse_down)
        end
    end
    if self._vt_arrow_dir or self._vt_repeat_task or self._vt_last_pan_pos then
        self:_gesLog("TOUCH-reset")
        self:_stopArrowRepeat()
        self._vt_last_pan_pos = nil
    end
    return false
end

-- 慢速拖动(pan)与长按拖动(hold_pan)同语义: 滑动触发模型(见 _startRepeatClock)
VTermView.onVTermPan = VTermView.onVTermHoldPan
VTermView.onVTermPanRelease = VTermView.onVTermHoldPanRelease

-- 滑动触发模型(用户定稿 2026-11-08 事件驱动版):
--   一次滑动/换向 → 立即发一次; 同向拖动累计满 SWIPE_UNIT 才再发(防误触);
--   手指停在原地满 1 秒 → 0.12s 节奏连发(在 pan 事件回调里判定, 不依赖定时器);
--   手指抬起 → 立即停。
-- ⚠️弃用 UIManager:scheduleIn 连发: 设备上手指按住时主循环阻塞等输入,
-- 定时器到期不执行(实测 REPEAT_START 有、TICK 零), 连发永不启动。


-- 手指抬起(release)/关开关: 立即停
function VTermView:_stopArrowRepeat()
    self._vt_arrow_dir = nil
    self._vt_pan_acc = 0 -- 手势结束: 位移累加清零, 防跨手势残留误发
    self._vt_still_since = nil -- 停住起点清零(下次按压重新计时)
    self:_stopRepeatClock()
end

-- ==================== 渲染与局部刷屏 ====================

function VTermView:setDirtyRegion(start_row, end_row)
    local r1 = math.max(0, start_row)
    local r2 = math.min(self.rows - 1, end_row)
    if r2 < r1 then return end
    local off = self._inner_off
    local refresh_region = Geom:new{
        x = self.dimen.x + off,
        y = self.dimen.y + off + r1 * self.cell_h,
        w = self.cols * self.cell_w,
        h = (r2 - r1 + 1) * self.cell_h,
    }
    -- 关键: 标脏到顶层对话框(UIManager 只消费顶层 widget 的脏区)
    self:queueDirty(refresh_region)
end

-- 光标移动不再脏化新旧两整行(滚动输出时的频闪主因): 只脏新旧两格的窄条。
-- 输出场景 damage 已覆盖所在行, bbox 合并后窄条不放大刷新区; 纯回车/退格
-- 这类无 damage 的移动就只剩两格窄条, e-ink 刷新面积从两行降到两格。
function VTermView:cursorMoved(old_row, old_col, row, col)
    local off = self._inner_off
    local ox, oy = self.dimen.x + off, self.dimen.y + off
    for _, rc in ipairs({ { old_row, old_col }, { row, col } }) do
        local r, c = rc[1], rc[2]
        if r >= 0 and r < self.rows and c >= 0 and c < self.cols then
            self:queueDirty(Geom:new{
                x = ox + c * self.cell_w,
                y = oy + r * self.cell_h,
                w = self.cell_w, h = self.cell_h,
            })
        end
    end
end

-- e-ink 防频闪: 80ms 合并窗口, 把连续的 damage/光标移动/输入条刷新
-- 合并成一次局部刷新(逐字符独立刷新会造成打字顿挫感)。
-- 突发自适应: 窗口期内又来 damage(输出突发, 如滚动日志)则把冲刷再推 100ms,
-- 突发期间约 180ms 一刷; 突发结束后最后一刷立即跟上, 静止打字仍 80ms 跟手。
-- 大范围重绘(清屏/全屏 TUI, ≥60% 网格)升级 "ui" 波形去残影, 小区域仍 "fast"。
local BURST_EXTRA = 0.10

function VTermView:_vtFlush()
    self._vt_refresh_pending = false
    self._vt_extended = false
    self._vt_refresh_fn = nil
    if not self._vt_dirty then return end
    local mode = "fast"
    local gw, gh = self.cols * self.cell_w, self.rows * self.cell_h
    if self.dimen and self.dimen.x and gw > 0 and gh > 0
        and self._vt_dirty.w * self._vt_dirty.h >= 0.6 * gw * gh then
        mode = "ui"
    end
    UIManager:setDirty(self.parent or self, mode, self._vt_dirty)
    self._vt_dirty = nil
end

function VTermView:queueDirty(region)
    if self._vt_dirty then
        local d = self._vt_dirty
        local x2 = math.max(d.x + d.w, region.x + region.w)
        local y2 = math.max(d.y + d.h, region.y + region.h)
        d.x = math.min(d.x, region.x)
        d.y = math.min(d.y, region.y)
        d.w = x2 - d.x
        d.h = y2 - d.y
    else
        self._vt_dirty = Geom:new{ x = region.x, y = region.y, w = region.w, h = region.h }
    end
    if self._vt_refresh_pending then
        -- 突发中: 每轮合并只延期一次(80→+100ms), 防饥饿(连续输出约 180ms 一刷)
        if not self._vt_extended and self._vt_refresh_fn then
            UIManager:unschedule(self._vt_refresh_fn)
            self._vt_refresh_fn = nil
            local fn = function() self:_vtFlush() end
            self._vt_refresh_fn = fn
            UIManager:scheduleIn(BURST_EXTRA, fn)
        end
        return
    end
    self._vt_refresh_pending = true
    self._vt_extended = false
    local fn = function() self:_vtFlush() end
    self._vt_refresh_fn = fn
    UIManager:scheduleIn(0.08, fn)
end

function VTermView:paintTo(bb, x, y)
    -- 记录绝对位置,供 setDirtyRegion 换算屏幕坐标
    self.dimen.x = x
    self.dimen.y = y

    local off = self._inner_off
    local gx = x + off
    local gy = y + off
    local gw = self.cols * self.cell_w
    local gh = self.rows * self.cell_h

    -- 纯白背景打底(覆盖到条带下沿 = 整个分配区含 InputText 下内边距)
    local avail_h = self.avail_rows_h or gh
    bb:paintRect(gx, gy, gw, avail_h + (self.bar_h or 0) + (self._inner_off or 0), Blitbuffer.COLOR_WHITE)

    if not self.screen then return end

    local screen = self.screen
    local vt_lib = self.vt_lib
    local cell = self._cell_tmp
    local pos = self._pos_tmp
    local cell_w = self.cell_w
    local cell_h = self.cell_h
    local baseline = self.baseline

    for r = 0, self.rows - 1 do
        pos.row = r -- 共享 _pos_tmp: 翻看分支不用它, 实时分支每行必须重设
        -- 翻看历史时优先用 scrollback 的行快照(实时屏仍在 libvterm 里)
        local row_cells = self._vt_sb and self._vt_sb:rowCells(r)
        if row_cells then
            local c = 0
            while c < self.cols do
                local cell_r = row_cells[c]
                local w = tonumber(cell_r.width) or 1
                local codepoint = cell_r.chars[0]
                -- 背景(选区灰度/反色)先画: 空格子(chars[0]=0)也画, 否则
                -- vim VISUAL 选区延伸到行尾空白时高亮"看不出来"
                local bgc = cell_r.bg and self:_cellBgGray(cell_r)
                if not bgc and cell_r.attrs.reverse == 1 then
                    bgc = Blitbuffer.COLOR_BLACK
                end
                if bgc then
                    bb:paintRect(gx + c * cell_w, gy + r * cell_h,
                        (w > 0 and w or 1) * cell_w, cell_h, bgc)
                end
                if w > 0 and codepoint ~= 0 and codepoint ~= 0xFFFFFFFF then
                    local is_cjk = (w == 2)
                    local face = is_cjk and self.face_cjk or self.face_mono
                    local glyph = RenderText:getGlyph(face, codepoint, cell_r.attrs.bold == 1)
                    local px = gx + c * cell_w
                    local py = gy + r * cell_h + baseline
                    local fg = (cell_r.attrs.reverse == 1) and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
                    if glyph and glyph.bb then
                        bb:colorblitFrom(glyph.bb, px + glyph.l, py - glyph.t, 0, 0,
                            glyph.bb:getWidth(), glyph.bb:getHeight(), fg)
                    end
                    c = c + w
                else
                    c = c + 1
                end
            end
        else
            local c = 0
            while c < self.cols do
                pos.col = c
                vt_lib.vterm_screen_get_cell(screen, pos, cell)
                local w = tonumber(cell.width)
                local codepoint = cell.chars[0]

                -- 背景(选区灰度/反色)先画: 空格子也画(同 row_cells 分支)
                local bgc = self:_cellBgGray(cell)
                if not bgc and cell.attrs.reverse == 1 then
                    bgc = Blitbuffer.COLOR_BLACK
                end
                if bgc then
                    bb:paintRect(gx + c * cell_w, gy + r * cell_h,
                        (w > 0 and w or 1) * cell_w, cell_h, bgc)
                end

                if w > 0 and codepoint ~= 0 and codepoint ~= 0xFFFFFFFF then
                    local is_bold = (cell.attrs.bold == 1)
                    local is_cjk = (w == 2)
                    local face = is_cjk and self.face_cjk or self.face_mono
                    local glyph = RenderText:getGlyph(face, codepoint, is_bold)

                    local px = gx + c * cell_w
                    local py = gy + r * cell_h + baseline

                    local fg_color = (cell.attrs.reverse == 1) and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK

                    if glyph and glyph.bb then
                        bb:colorblitFrom(
                            glyph.bb,
                            px + glyph.l,
                            py - glyph.t,
                            0, 0,
                            glyph.bb:getWidth(),
                            glyph.bb:getHeight(),
                            fg_color
                        )
                    end
                    c = c + w
                else
                    c = c + 1
                end
            end
        end
    end

    -- 绘制终端光标(翻看历史时不画: 光标属于实时屏)
    if not (self._vt_sb and self._vt_sb:isScrolling()) then
        local state = vt_lib.vterm_obtain_state(self.vt)
        local cur_pos = ffi.new("VTermPos")
        vt_lib.vterm_state_get_cursorpos(state, cur_pos)
        if cur_pos.row >= 0 and cur_pos.row < self.rows and cur_pos.col >= 0 and cur_pos.col < self.cols then
            local cur_x = gx + cur_pos.col * cell_w
            local cur_y = gy + cur_pos.row * cell_h
            bb:invertRect(cur_x, cur_y, cell_w, cell_h)
        end
    end

    -- 临时探针: 选区高亮排障(/tmp/vt_attr.on 存在时采样整屏属性分布),
    -- 统计 reverse/下划线/非默认背景色号, 用完删。必须在条带分支提前
    -- return(bar_h<=0 / 收起)之前, 否则 EN 布局采样不到。
    if io.open("/tmp/vt_attr.on", "r") then
        local n_rev, n_ul, n_bg = 0, 0, 0
        local bg_seen = {}
        local pc = ffi.new("VTermPos")
        for r = 0, self.rows - 1 do
            pc.row = r
            for c = 0, self.cols - 1 do
                pc.col = c
                vt_lib.vterm_screen_get_cell(screen, pc, cell)
                if cell.attrs.reverse == 1 then n_rev = n_rev + 1 end
                if cell.attrs.underline == 1 then n_ul = n_ul + 1 end
                local t = tonumber(cell.bg.type) or 0
                if bit.band(t, 0x04) == 0 and bit.band(t, 0x01) ~= 0 then
                    local idx = tonumber(cell.bg.indexed.idx) or -1
                    n_bg = n_bg + 1
                    bg_seen[idx] = (bg_seen[idx] or 0) + 1
                end
            end
        end
        local parts = {}
        for idx, n in pairs(bg_seen) do parts[#parts + 1] = idx .. "x" .. n end
        local lf = io.open("/tmp/vt_attr.log", "a")
        if lf then
            lf:write(os.date("%H:%M:%S"), " rev=", n_rev, " ul=", n_ul,
                " bg=", n_bg, " [", table.concat(parts, ","), "]\n")
            lf:close()
        end
    end

    -- 候选字条(独占键盘上方的窄条带: 下沿即按钮行, 无下边线; 上沿细线紧贴
    -- 网格末行)。仅 IME(zh 系)布局显示候选文字; EN 等直通布局只留白底。
    local avail_h = self.avail_rows_h or (self.rows * cell_h)
    local grid_bottom = gy + self.rows * cell_h
    -- 条带下沿要吃到底: InputText 自身的下内边距(margin+border+padding)在
    -- 我们的绘制区之外, 但它仍是白底, 继续向下铺满才能让候选字真正贴住
    -- 键盘按钮行(否则会留一条 20 多像素的空白)
    local band_bottom = gy + avail_h + (self.bar_h or 0) + (self._inner_off or 0)
    if self._vt_bar_visible == false then return end
    if (self.bar_h or 0) <= 0 then return end -- 直通布局: 条带高度已归零
    bb:paintRect(gx, grid_bottom, gw, band_bottom - grid_bottom, Blitbuffer.COLOR_WHITE)
    bb:paintRect(gx, grid_bottom, gw, 2, Blitbuffer.COLOR_LIGHT_GRAY)
    local draft = (self._vt_bar_line or "")
        .. table.concat(self.charlist, "", self._vt_sent + 1, #self.charlist)
    if draft ~= "" then
        local max_w = gw - 8
        local tw = TextWidget:new{ text = draft, face = self.bar_face, fgcolor = Blitbuffer.COLOR_BLACK }
        if tw:getSize().w > max_w then
            draft = RenderText:getSubTextByWidth(draft, self.bar_face, max_w - cell_w, false, false) .. "…"
            tw:free()
            tw = TextWidget:new{ text = draft, face = self.bar_face, fgcolor = Blitbuffer.COLOR_BLACK }
        end
        -- 墨迹在条带内垂直居中(行盒留白不再决定位置): 上方到分割线、下方到
        -- 键盘的空白相等, 不再出现"字贴着键盘、顶上却空一大截"
        local area_top = grid_bottom + 2
        local area_h = band_bottom - area_top
        local ink_top_y = area_top
            + math.max(0, math.floor((area_h - (self.cjk_ink_h or 0)) / 2))
        local baseline = ink_top_y + (self.cjk_ink_t or 0)
        local ty = baseline - tw:getBaseline()
        if ty < gy then ty = gy end
        tw:paintTo(bb, gx + 4, ty)
        tw:free()
    end
end

return VTermView
