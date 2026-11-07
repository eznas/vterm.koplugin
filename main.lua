local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local PTY = require("pty")
local Scrollback = require("scrollback")
local SessionMgr = require("session_mgr")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local VTermFFI = require("vterm_ffi")
local VTermView = require("vterm_view")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local gettext = require("gettext")
-- 轻量双语: 文案原文即中文; KOReader 界面语言非 zh* 时自动切英文对照表
-- (中文走 gettext 原样返回; 每次调用现读语言, 菜单重建即切换, 无需重启)
local EN_STRS = {
    ["VTerm 增强终端 (PuTTY)"] = "VTerm Enhanced Terminal (PuTTY)",
    ["打开 VTerm 终端"] = "Open VTerm Terminal",
    ["本地 Shell (Bash / Vim)"] = "Local Shell (Bash / Vim)",
    ["+ 新建远程 SSH 会话"] = "+ New Remote SSH Session",
    ["新建远程 SSH 会话 (类似 PuTTY)"] = "New Remote SSH Session (PuTTY-like)",
    ["⚙ 设置"] = "⚙ Settings",
    ["已存会话 (长按编辑)"] = "Saved Sessions (hold to edit)",
    ["终端设置"] = "Terminal Settings",
    ["字体大小"] = "Font Size",
    ["历史行数"] = "Scrollback Lines",
    ["恢复默认"] = "Restore Defaults",
    ["应用"] = "Apply",
    ["取消"] = "Cancel",
    ["保留"] = "Keep",
    ["删除"] = "Delete",
    ["另存为"] = "Save As",
    ["退出"] = "Exit",
    ["结束"] = "End",
    ["Esc"] = "Esc",
    [" ?"] = " ?",
    ["标题栏显示电量与时间"] = "Battery & clock in title bar",
    ["会话名称 (如: 我的VPS/Termux)"] = "Session name (e.g. my VPS/Termux)",
    ["主机 IP 或域名"] = "Host IP or domain",
    ["端口号 (默认 22)"] = "Port (default 22)",
    ["用户名 (如: root / ubuntu)"] = "Username (e.g. root / ubuntu)",
    ["私钥路径 (选填,留空则密码认证)"] = "Private key path (optional; empty = password)",
    ["保存连接"] = "Save Connection",
    ["已存会话"] = "Saved Sessions",
    ["删除会话配置: "] = "Delete session config: ",
    ["编辑会话: "] = "Edit session: ",
    ["已删除: "] = "Deleted: ",
    ["已另存为: "] = "Saved as: ",
    ["结束当前终端会话?"] = "End current terminal session?",
}
local function _isZhUi()
    local ok, lang = pcall(function()
        return rawget(_G, "G_reader_settings") and G_reader_settings:readSetting("language")
    end)
    if not ok or not lang then return true end -- 无配置(模拟器/测试)默认中文原文
    return lang:find("^zh") ~= nil
end
local _ = function(s)
    if _isZhUi() then return gettext(s) end
    return EN_STRS[s] or s
end
local ffi = require("ffi")

local VTermPlugin = WidgetContainer:extend{
    name = "vterm",
    pty = nil,
    vt = nil,
    screen = nil,
    vt_lib = nil,
    view = nil,
    dialog = nil,
    session_mgr = nil,
}

function VTermPlugin:init()
    self.vt_lib = VTermFFI.load(self.path)
    self.session_mgr = SessionMgr.new(self.path .. "/sessions.json", self.path)
    self:ensureLocale() -- 首次启动编译 UTF-8 locale(后台一次, 失败无碍)

    -- 收割上次异常退出残留的 shell(KOReader 崩溃时 closeTerminal 没跑,
    -- 僵尸 shell 会一直占着 PTY/终端)
    pcall(function()
        local f = io.open(self.path .. "/terminal.pid", "r")
        if not f then return end
        local pid = tonumber(f:read("*l"))
        f:close()
        if pid and PTY.reapStale(pid) then
            print("[VTerm] reaped stale shell pid " .. pid)
        end
        os.remove(self.path .. "/terminal.pid")
    end)

    -- 1. 注册主菜单 (文件管理器主界面)
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- 2. 注册阅读器菜单 (看书时在顶部工具菜单中也能唤起)
    if self.view and self.view.menu then
        self.view.menu:registerToMainMenu(self)
    end

    -- 3. 注册 Dispatcher 快捷动作 (支持手势一键呼出)
    if Dispatcher and Dispatcher.registerAction then
        Dispatcher:registerAction("vterm_open_terminal", {
            category = "none",
            event = "OpenVTerm",
            title = _("打开 VTerm 终端"),
            general = true,
        })
    end

    -- 4. 模拟器自动化测试钩子 (真机环境变量不存在, 不受影响)
    -- =1: 启动后自动开终端; =2: zh_CN 拼音 IME 回归(组词→回车提交→CJK 回显);
    -- =3: vim 中文全流程(vim 打开→zh 组词提交 你好→:wq 落盘)
    -- =4: 中英输入/删除组合回归套件(真机全链路, 断言落盘 autotest.log)
    -- =8: 快捷栏改版回归(按钮条组成/Ctrl 下划线/方向手势开关/Scrollback 翻看)
    local autotest = os.getenv("VTERM_AUTOTEST")
    -- 真机无人值守测试开关: 插件目录放 imetest.on → 启动后自动跑 IME-vim 用例
    -- (真机 KUAL 启动无法注入环境变量; 测完删除该文件即恢复正常)
    if not autotest then
        local ff = io.open(self.path .. "/imetest.on", "r")
        if ff then
            -- 文件内容写模式号(如 "4"), 空文件默认 12; 套件收尾自动删除
            local m = ff:read("*a") or ""
            ff:close()
            autotest = m:match("^%s*(%d+)%s*$") or "12"
        end
    end
    if autotest == "1" or autotest == "2" or autotest == "3" or autotest == "4"
        or autotest == "5" or autotest == "6" or autotest == "7" or autotest == "8"
        or autotest == "9" or autotest == "10" or autotest == "11" or autotest == "12"
        or autotest == "13" then
        if autotest == "2" or autotest == "11" then
            G_reader_settings:saveSetting("keyboard_layout", "zh_CN")
        end
        if autotest == "4" or autotest == "5" or autotest == "12" or autotest == "13" then
            G_reader_settings:saveSetting("keyboard_layout", "en") -- 直接 addChars 注入中文
        end
        UIManager:scheduleIn(3, function()
            if autotest == "4" or autotest == "5" then
                -- 用 sessions.json 第一个会话(与用户真实会话一致的 cmd/args)
                local sessions = self.session_mgr:list()
                self:startTerminal(#sessions > 0 and sessions[1] or { type = "local" })
            else
                self:startTerminal({ type = "local" })
            end
        end)
    end
    if autotest == "4" then
        self:_runComboSuite()
    end
    if autotest == "11" then
        self:_runLayoutSwitchSuite()
    end
    if autotest == "5" then
        self:_runVimSuite()
    end
    if autotest == "12" then
        self:_runImeVimSuite()
    end
    if autotest == "13" then
        self:_runVimWrapSuite()
    end
    if autotest == "6" then
        -- 纯视觉实证: seq 填网格 + 执行一条中文 echo(网格真 UTF-8) + 候选字条
        -- 置为组词中状态, 最后自动截图到插件目录 zh_shot.png(供人工核对:
        -- 中文显示/条带布局/候选不遮挡终端输出)
        G_reader_settings:saveSetting("keyboard_layout", "zh_CN")
        UIManager:scheduleIn(4.5, function()
            if self.view then self.view:sendBytes("seq 1 60\n") end
        end)
        UIManager:scheduleIn(6.0, function()
            -- sendBytes 绕过 IME 草稿(整串中文经 addChars 会被当拼音组词不提交)
            if self.view then self.view:sendBytes("echo 中文输入效果：你好，世界！\n") end
        end)
        UIManager:scheduleIn(8.0, function()
            if not self.view then return end
            local v = self.view
            -- 组词中状态: 已提交前缀 + 拼音草稿 + 候选列表
            v._vt_bar_line = "echo 中文 "
            table.insert(v.charlist, "n")
            table.insert(v.charlist, "i")
            table.insert(v.charlist, "[你呢呢]")
            v:refreshInputBar()
            local f = io.open(self.path .. "/autotest.log", "a")
            if f then
                f:write(("GEOM height=%s avail=%s rows=%s cell_h=%s bar_h=%s ink_h=%s desc=%s off=%s dimen_y=%s\n")
                    :format(tostring(v.height), tostring(v.avail_rows_h), tostring(v.rows),
                        tostring(v.cell_h), tostring(v.bar_h), tostring(v.cjk_ink_h),
                        tostring(v.cjk_desc), tostring(v._inner_off), tostring(v.dimen and v.dimen.y)))
                f:close()
            end
        end)
        UIManager:scheduleIn(9.0, function()
            local ok = pcall(function()
                require("device").screen:shot(self.path .. "/zh_shot.png")
            end)
            local f = io.open(self.path .. "/autotest.log", "a")
            if f then f:write("SHOT ", ok and "OK" or "FAIL", "\n") f:close() end
        end)
        -- 对照图: 切 en 布局(条带归零, 网格多吃 1 行)后再截图
        UIManager:scheduleIn(10.0, function()
            if self.view and self.view.keyboard then
                self.view.keyboard:setKeyboardLayout("en")
            end
        end)
        UIManager:scheduleIn(10.5, function()
            if self.view then self.view:sendBytes("seq 1 70\n") end
        end)
        UIManager:scheduleIn(12.0, function()
            local ok = pcall(function()
                require("device").screen:shot(self.path .. "/no_bar_shot.png")
            end)
            local f = io.open(self.path .. "/autotest.log", "a")
            if f then
                f:write("SHOT_EN ", ok and "OK" or "FAIL",
                    " rows=", tostring(self.view and self.view.rows),
                    " bar_h=", tostring(self.view and self.view.bar_h), "\n")
                f:close()
            end
        end)
    end
    if autotest == "7" then
        -- 复现"vim 输入单字出现多余空格": vi 内逐字输入单个汉字, 每步
        -- 断言首行内容恰为已输字符拼接(无多余空格/残影), 结果落盘
        G_reader_settings:saveSetting("keyboard_layout", "en")
        local t = 3.2
        local function at(dt, fn)
            t = t + dt
            UIManager:scheduleIn(t, function()
                if self.pty and self.pty:isAlive() then fn() end
            end)
        end
        at(0.1, function()
            local f = io.open(self.path .. "/autotest.log", "w")
            if f then f:write("SINGLE-CHAR SUITE START\n") f:close() end
        end)
        at(0.2, function() self.view:sendBytes("rm -f /tmp/vt7.txt\n") end)
        at(0.5, function() self.view:addChars("vim /tmp/vt7.txt") end)
        at(0.6, function() self.view:addChars("\n") end)
        at(1.5, function() self.view:addChars("i") end)
        -- 切 zh 布局, 用真实 IME 按键逐字输入: n→i→空格(提交 你), 每字后断言
        local kb_layout = function(name)
            if self.view and self.view.keyboard then
                self.view.keyboard:setKeyboardLayout(name)
            end
        end
        at(0.4, function() kb_layout("zh_CN") end)
        -- n,i,空格 → 提交"你"; s,i,空格 → "死"; a,空格 → "啊"; b,空格 → "吧"
        -- h,a,o,空格 → "好"。空格前的字母是组词, 空格才提交。
        local chars = { "n", "i", " ", "s", "i", " ", "a", " ", "b", " ", "h", "a", "o", " " }
        local expects = { [3] = "你", [6] = "你死", [8] = "你死啊",
                          [10] = "你死啊吧", [14] = "你死啊吧好" }
        for idx = 1, #chars do
            at(0.5, function() self.view:addChars(chars[idx]) end)
            if expects[idx] then
                at(0.15, function()
                    local ok, detail = pcall(function()
                        local cell, pos = ffi.new("VTermScreenCell"), ffi.new("VTermPos")
                        local line, c = "", 0
                        while c < self.view.cols do
                            pos.row, pos.col = 0, c
                            self.vt_lib.vterm_screen_get_cell(self.screen, pos, cell)
                            local cp = cell.chars[0]
                            if cp >= 32 and cp < 0x10FFFF and cp ~= 0xFFFFFFFF then
                                local b1 = cp < 128 and string.char(cp)
                                    or cp < 2048 and string.char(192 + math.floor(cp / 64), 128 + cp % 64)
                                    or string.char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64)
                                line = line .. b1
                            end
                            if tonumber(cell.width) == 2 then c = c + 2 else c = c + 1 end
                        end
                        -- 截掉首行尾部空格填充
                        line = line:gsub("%s+$", "")
                        assert(line == expects[idx], ("第%d键后首行=%q 期望=%q"):format(idx, line, expects[idx]))
                    end)
                    self:_suiteLog(("S%02d 键%s: %s | %s"):format(idx, chars[idx],
                        ok and "PASS" or "FAIL", tostring(detail)))
                end)
            end
        end
        at(0.5, function() self:_suiteLog("SUITE DONE") end)
    end
    if autotest == "8" then
        self:_runToolbarSuite()
    end
    if autotest == "9" then
        -- ⌨ 软键盘+按钮栏同步收放留证: startTerminal(白名单 3s)→收起→截图→退出。
        -- 收起走 ⌨ 同款重建路径, 记录收起前后 rows(终端行数应变多)。
        -- ⚠️ closeTerminal 退出码 85 会让 koreader.sh 重启循环拉起 KOReader 重跑
        -- 本流程并覆盖截图 → 用 /tmp 标志防重跑(重启后只普通开终端)。
        local done_flag = "/tmp/vt_mode9_done"
        local df = io.open(done_flag, "r")
        if df then
            df:close()
        else
            local wf = io.open(done_flag, "w")
            if wf then wf:write("1") wf:close() end
            local function at(dt, fn) UIManager:scheduleIn(dt, fn) end
            at(6.0, function()
                local v = self.view
                if not v then self:_suiteLog("KB no-view") return end
                local before = v.isKeyboardVisible and v:isKeyboardVisible()
                local rows0 = v.rows
                self:_toggleKeyboardBar()
                local v2 = self.view
                local after = v2.isKeyboardVisible and v2:isKeyboardVisible()
                self:_suiteLog(("KB TOGGLE %s->%s rows %d->%d view_new=%s"):format(
                    tostring(before), tostring(after), rows0, v2.rows, tostring(v2 ~= v)))
            end)
            at(10.0, function()
                local v = self.view
                self:_suiteLog("KB ATSHOT " .. tostring(v and v.isKeyboardVisible and v:isKeyboardVisible())
                    .. " collapsed=" .. tostring(v and v._vt_collapsed) .. " rows=" .. tostring(v and v.rows))
                local ok = pcall(function()
                    local Screenshoter = require("ui/widget/screenshoter")
                    Screenshoter:new{ ui = self.ui }:onScreenshot("vterm_kb_hidden")
                end)
                self:_suiteLog("KBHIDDEN SHOT " .. (ok and "OK" or "FAIL"))
            end)
            at(13.0, function() self:closeTerminal() end)
        end
    end
    if autotest == "10" then
        -- ⌨ 收放后的触摸/手势注入自检: 展开态 swipe → 收起 → 收起态 tap 唤回 →
        -- 唤回后 swipe 仍通。每步落 autotest.log, 用于定位"⇆/⇕ 开启后终端无响应"。
        local done_flag = "/tmp/vt_mode10_done"
        local df = io.open(done_flag, "r")
        if df then
            df:close()
        else
            local wf = io.open(done_flag, "w")
            if wf then wf:write("1") wf:close() end
            local function at(dt, fn) UIManager:scheduleIn(dt, fn) end
            local function gesAt(ges)
                return self.dialog:handleEvent(require("ui/event"):new("Gesture", ges))
            end
            at(5.0, function()
                local Geom = require("ui/geometry")
                local v = self.view
                v:setArrowGestures(true)
                local sent = {}
                local orig = v._vt_write
                v._vt_write = function(s) sent[#sent + 1] = s end
                local r = gesAt({ ges = "swipe", direction = "left",
                    pos = Geom:new{ x = v.dimen.x + 40, y = v.dimen.y + 40 } })
                v._vt_write = orig
                self:_suiteLog("M10 SWIPE-open handled=" .. tostring(r) .. " sent=" .. (sent[1] or "none"))
            end)
            at(7.0, function()
                self:_toggleKeyboardBar()
                local v = self.view
                self:_suiteLog("M10 COLLAPSE kb=" .. tostring(v:isKeyboardVisible())
                    .. " collapsed=" .. tostring(v._vt_collapsed) .. " rows=" .. v.rows
                    .. " arrows=" .. tostring(v._vt_arrows))
            end)
            at(9.0, function()
                local Geom = require("ui/geometry")
                local v0 = self.view
                local pos = Geom:new{
                    x = v0.dimen.x + math.floor(v0.cols * v0.cell_w / 2),
                    y = v0.dimen.y + math.floor(v0.rows * v0.cell_h / 2),
                }
                gesAt({ ges = "tap", pos = pos })
                local v2 = self.view
                self:_suiteLog("M10 TAP-collapsed view_new=" .. tostring(v2 ~= v0)
                    .. " kb=" .. tostring(v2:isKeyboardVisible())
                    .. " collapsed=" .. tostring(v2._vt_collapsed))
            end)
            at(11.0, function()
                local Geom = require("ui/geometry")
                local v = self.view
                local sent = {}
                local orig = v._vt_write
                v._vt_write = function(s) sent[#sent + 1] = s end
                local r = gesAt({ ges = "swipe", direction = "right",
                    pos = Geom:new{ x = v.dimen.x + 40, y = v.dimen.y + 40 } })
                v._vt_write = orig
                self:_suiteLog("M10 SWIPE-restored handled=" .. tostring(r) .. " sent=" .. (sent[1] or "none"))
                v:setArrowGestures(false)
                if self._btn_arrow then self._btn_arrow:setText("⇆", self._btn_arrow.width) end
            end)
            at(13.0, function() self:closeTerminal() end)
        end
    end
    if autotest == "2" then
        -- 逐键注入(模拟真实节奏): n@5 i@5.4 组词; t+20 回车(直通, 提交 你+换行)
        UIManager:scheduleIn(5, function()
            if self.view then self.view:addChars("n") end
        end)
        UIManager:scheduleIn(5.4, function()
            if self.view then self.view:addChars("i") end
        end)
        UIManager:scheduleIn(20, function()
            if self.view then
                self.view:addChars("\n")
            end
        end)
    end
    if autotest == "3" then
        -- 英文命令需在 EN 布局下直通(zh 布局会被 IME 组词, stock 行为)
        G_reader_settings:saveSetting("keyboard_layout", "en")
        local kb_layout = function(name)
            if self.view and self.view.keyboard then
                self.view.keyboard:setKeyboardLayout(name)
            end
        end
        UIManager:scheduleIn(5, function()
            if self.view then self.view:addChars("vim /tmp/t.txt") end
        end)
        UIManager:scheduleIn(6, function()
            if self.view then self.view:addChars("\n") end
        end)
        UIManager:scheduleIn(8, function()
            if self.view then self.view:addChars("i") end -- vim 插入模式
        end)
        UIManager:scheduleIn(9, function() kb_layout("zh_CN") end)
        UIManager:scheduleIn(10, function()
            if self.view then
                self.view:addChars("n")
                self.view:addChars("i")
            end
        end)
        UIManager:scheduleIn(12, function()
            if self.view then self.view:addChars(" ") end -- 提交 你
        end)
        UIManager:scheduleIn(13, function()
            if self.view then self.view:addChars("h") end
        end)
        UIManager:scheduleIn(13.4, function()
            if self.view then self.view:addChars("a") end
        end)
        UIManager:scheduleIn(13.8, function()
            if self.view then self.view:addChars("o") end
        end)
        UIManager:scheduleIn(15, function()
            if self.view then self.view:addChars(" ") end -- 提交 好
        end)
        UIManager:scheduleIn(16, function() kb_layout("en") end)
        UIManager:scheduleIn(17, function()
            if self.view then self.view:addChars("\27") end -- Esc
        end)
        UIManager:scheduleIn(18, function()
            if self.view then self.view:addChars(":wq\n") end
        end)
    end
end

function VTermPlugin:onOpenVTerm()
    self:startTerminal({ type = "local" })
end

-- 确保插件目录下有可用的 zh_CN.utf8 locale(LOCPATH 生效目录)。
-- Kindle 系统 locale-archive 只有 POSIX, bash readline 因此按单字节处理
-- 中文(回显 ?、退格撕裂)。首次使用时用设备自带 localedef 编译一次到
-- /mnt/us(持久), 之后零开销。i18n 源文件已随插件打包在 locale_src/。
function VTermPlugin:ensureLocale()
    local locale_dir = self.path .. "/locale"
    local marker = locale_dir .. "/zh_CN.utf8"
    local f = io.open(marker, "r")
    if f then
        f:close()
        return true -- 已编译
    end
    local src_dir = self.path .. "/locale_src"
    os.execute('mkdir -p "' .. locale_dir .. '"')
    local cmd = string.format(
        'I18NPATH="%s" localedef -i zh_CN -f UTF-8 "%s" 2>/dev/null',
        src_dir, marker)
    os.execute(cmd)
    local chk = io.open(marker, "r")
    if chk then
        chk:close()
        return true
    end
    return false -- 编译失败也无妨, 回退到原有行为
end

function VTermPlugin:addToMainMenu(menu_items)
    menu_items.vterm = {
        text = _("VTerm 增强终端 (PuTTY)"),
        sorting_hint = "more_tools",
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
    }
end

function VTermPlugin:getSubMenuItems()
    local items = {
        {
            text = _("本地 Shell (Bash / Vim)"),
            callback = function()
                self:startTerminal({ type = "local" })
            end,
        },
        {
            text = _("+ 新建远程 SSH 会话"),
            callback = function()
                self:showSessionEditor()
            end,
        },
        {
            text = _("⚙ 设置"),
            callback = function()
                self:showSettings()
            end,
        },
    }

    local sessions = self.session_mgr:list()
    if #sessions > 1 then
        table.insert(items, { text = "--------- " .. _("已存会话 (长按编辑)") .. " ---------" })
        local n = 0
        for i, sess in ipairs(sessions) do
            if sess.type == "ssh" then
                n = n + 1
                local label = string.format("%d. %s (%s@%s:%s)", n, sess.name or "Unnamed", sess.user or "root", sess.host or "", sess.port or "22")
                table.insert(items, {
                    text = label,
                    callback = function()
                        self:startTerminal(sess)
                    end,
                    hold_callback = function()
                        self:showSessionEditor(sess, i)
                    end,
                })
            end
        end
    end

    return items
end

-- 会话参数编辑器: 新建(sess=nil)与编辑已存会话(带 sess+index)共用。
-- "保存" = 覆盖原会话(编辑) / 新增并连接(新建); "另存为新配置" = 总是新增一份, 不动原会话。
function VTermPlugin:showSessionEditor(sess, index)
    sess = sess or {}
    local dialog
    local function collect()
        local values = dialog:getFields()
        return {
            type = "ssh",
            name = (values[1] and values[1] ~= "") and values[1] or values[2],
            host = values[2],
            port = tonumber(values[3]) or 22,
            user = (values[4] and values[4] ~= "") and values[4] or "root",
            key_path = (values[5] and values[5] ~= "") and values[5] or nil,
        }
    end
    dialog = MultiInputDialog:new{
        title = index and (_("编辑会话: ") .. (sess.name or "")) or _("新建远程 SSH 会话 (类似 PuTTY)"),
        fields = {
            {
                description = _("会话名称 (如: 我的VPS/Termux)"),
                text = sess.name or "My Server",
            },
            {
                description = _("主机 IP 或域名"),
                text = sess.host or "",
            },
            {
                description = _("端口号 (默认 22)"),
                text = tostring(sess.port or 22),
            },
            {
                description = _("用户名 (如: root / ubuntu)"),
                text = sess.user or "root",
            },
            {
                description = _("私钥路径 (选填,留空则密码认证)"),
                text = sess.key_path or "",
            },
        },
        buttons = index and {
            {   -- 编辑模式: 一行四钮(文字已缩短)
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("删除"),
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text = _("删除会话配置: ") .. (sess.name or "") .. _(" ?"),
                            ok_text = _("删除"),
                            cancel_text = _("保留"),
                            ok_callback = function()
                                self.session_mgr:delete(index)
                                UIManager:close(dialog)
                                UIManager:show(InfoMessage:new{ text = _("已删除: ") .. (sess.name or ""), timeout = 2 })
                            end,
                        })
                    end,
                },
                {
                    text = _("另存为"),
                    callback = function()
                        local s = collect()
                        if s.host and #s.host > 0 then
                            self.session_mgr:add(s)
                            UIManager:close(dialog)
                            UIManager:show(InfoMessage:new{ text = _("已另存为: ") .. (s.name or s.host), timeout = 2 })
                        end
                    end,
                },
                {
                    text = _("保存连接"),
                    callback = function()
                        local s = collect()
                        if s.host and #s.host > 0 then
                            self.session_mgr:update(index, s)
                            UIManager:close(dialog)
                            self:startTerminal(s)
                        end
                    end,
                },
            },
        } or {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("保存连接"),
                    callback = function()
                        local s = collect()
                        if s.host and #s.host > 0 then
                            self.session_mgr:add(s)
                            UIManager:close(dialog)
                            self:startTerminal(s)
                        end
                    end,
                },
            }
        },
    }
    -- 按钮栏移到标题下方: MultiInputDialog 字段多、对话框高, 软键盘弹出时
    -- 底部按钮会被键盘遮挡无法点击; 放顶部永远可点。
    local btns = dialog.vgroup[#dialog.vgroup]
    if btns then
        table.remove(dialog.vgroup)
        table.insert(dialog.vgroup, 2, btns)
        dialog.vgroup:resetLayout()
    end
    UIManager:show(dialog)
end

function VTermPlugin:startTerminal(session, opts)
    session = session or { type = "local" }
    self._vt_session = session

    local cmd, args = self.session_mgr:buildLaunchCommand(session)

    -- 统一发送通道: 经 view 的草稿提交规则(IME 安全)后写入 PTY 并回读刷新
    local function sendInput(seq)
        if self.view then
            self.view:sendBytes(seq)
        end
    end

    local title_text = (session.type == "ssh") and string.format("SSH: %s (%s)", session.name or "Host", session.host) or "VTerm Terminal"

    -- 构造标准的 InputDialog 按钮表 (由底层 ButtonTable 严格分配触控区域)
    -- 开关状态显示: Button:callback() 不传参、text 也不解析 <u> 标记,
    -- 因此在对话框构造后按文字抓回 Button 引用, 用 btn:setText 换 "*"
    -- 后缀表示激活(纯 ASCII, 任何字体都有)。
    local buttons_layout = {
        {
            {
                text = _("Esc"),
                callback = function() sendInput("\27") end,
            },
            {
                text = "↹", -- Tab
                callback = function() sendInput("\t") end,
            },
            {
                text = "Ctrl", -- 激活时加 * (只作用于下一次输入, 用掉自动撤销)
                callback = function()
                    if not self.view then return end
                    self.view._vt_ctrl_pending = not self.view._vt_ctrl_pending
                    if self._btn_ctrl then
                        self._btn_ctrl:setText(self.view._vt_ctrl_pending and "Ctrl*" or "Ctrl", self._btn_ctrl.width)
                    end
                    if self.dialog then UIManager:setDirty(self.dialog, "ui") end
                end,
            },
            {
                -- 软键盘+按钮栏同步收放: 收起后终端网格吃掉两者空间(行数变多),
                -- 收起状态 tap 网格唤回。走 InputDialog:toggleKeyboard 官方重建路径
                -- (布局真正重排); 本按钮必须带 id="keyboard" —— 重建收尾要找它
                -- (inputdialog.lua:715 getButtonById("keyboard"):onUnfocus), 缺了闪退。
                -- 重建会换掉 VTermView 实例, 因此 callback 之后必须 _reattachVTerm。
                id = "keyboard",
                text = "⌨",
                callback = function() self:_toggleKeyboardBar() end,
            },
            {
                text = ":",
                callback = function() sendInput(":") end,
            },
            {
                text = "/",
                callback = function() sendInput("/") end,
            },
            {
                text = "↑",
                callback = function() sendInput("\27[A") end,
            },
            {
                text = "↓",
                callback = function() sendInput("\27[B") end,
            },
            {
                text = "⇆", -- 方向手势开关
                callback = function()
                    local v = self.view
                    if not v then return end
                    v:setArrowGestures(not v._vt_arrows)
                    if self._btn_arrow then
                        self._btn_arrow:setText(v._vt_arrows and "⇆*" or "⇆", self._btn_arrow.width)
                    end
                    if self.dialog then UIManager:setDirty(self.dialog, "ui") end
                end,
            },
            {
                text = "⇕", -- 翻页层开关: ⇆关=发远端 PageUp/PageDown, ⇆开=本地历史翻页
                callback = function()
                    local v = self.view
                    if not v then return end
                    v._vt_sb_mode = not v._vt_sb_mode
                    if self._btn_sb then
                        self._btn_sb:setText(v._vt_sb_mode and "⇕*" or "⇕", self._btn_sb.width)
                    end
                    if self.dialog then UIManager:setDirty(self.dialog, "ui") end
                end,
            },
            {
                text = _("退出"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("结束当前终端会话?"),
                        ok_text = _("结束"),
                        cancel_text = _("取消"),
                        ok_callback = function() self:closeTerminal() end,
                    })
                end,
            },
        }
    }

    -- 键盘输入经 VTermView 的沙箱提交规则处理(IME 安全), 无需额外回调

    -- 1. 唯一实例化 InputDialog：让它创建唯一的 VTermView 实例
    self.dialog = InputDialog:new{
        title = title_text,
        input = "",
        input_type = "string",
        allow_newline = false,
        cursor_at_end = true,
        fullscreen = true,
        condensed = true, -- 网格吃满全宽(去掉两侧 10% 留白),终端列数最大化
        inputtext_class = VTermView,
        buttons = buttons_layout,
    }

    -- 2. 获取真正的单例输入视口组件
    local view = self.dialog._input_widget
    self.view = view
    view._vt_local = (session.type ~= "ssh") -- 本地会话需适配 busybox vi 字节级退格
    view._vt_plugin_path = self.path -- 手势实测记录(geslog.on)的开关/日志路径
    -- 默认态(⇆关)也必须注册基础手势: 否则全新会话里 ⇕ 开启后上下滑无人处理
    -- (以前只有切换过 ⇆ 才会走到 setArrowGestures, 首启默认状态手势全丢)
    view:setArrowGestures(false)

    -- 标题栏电量与时间(可在菜单里关闭): 序号失效旧刷新链后重挂
    self._title_seq = (self._title_seq or 0) + 1
    self:_patchTitleBar()

    -- ButtonTable 把配置表重建成了 Button 对象, 回调又不传参(self.callback()),
    -- 所以这里按文字把按钮引用抓回来, 开关状态才能改显示。
    -- 引用挂在 self 上: dialog:toggleKeyboard 重建后按钮对象是新的,
    -- _reattachVTerm 会重抓, 局部 upvalue 捕获会指向死按钮。
    local function findBtn(txt)
        local bt = self.dialog.button_table
        if not bt or not bt.buttons_layout then return nil end
        for _, row in ipairs(bt.buttons_layout) do
            for _, b in ipairs(row) do
                if type(b) == "table" and b.text == txt then return b end
            end
        end
    end
    self._btn_ctrl = findBtn("Ctrl")
    self._btn_arrow = findBtn("⇆")
    self._btn_sb = findBtn("⇕")
    view._vt_ctrl_btn = self._btn_ctrl -- 供回归套件断言
    -- Ctrl 是一次性修饰, 用掉后由 view 回调撤掉 *
    view._vt_on_ctrl_used = function()
        if self._btn_ctrl then self._btn_ctrl:setText("Ctrl", self._btn_ctrl.width) end
        if self.dialog then UIManager:setDirty(self.dialog, "ui") end
    end
    -- 收起状态(按钮栏+键盘全收)下 tap 网格唤回的通道
    view._vt_toggle_cb = function() self:_toggleKeyboardBar() end

    -- 4. 初始化底层 libvterm 状态机
    -- 字号设置等"仅重建对话框"路径: 终端状态(vt/screen/scrollback/PTY)不重建,
    -- 由 _reattachVTerm 原样挂回新 view 并按新格子尺寸 resize。
    if opts and opts.reuse then
        self:_reattachVTerm()
        UIManager:show(self.dialog)
        self.dialog:onShowKeyboard(true)
        return
    end
    local vt, screen = VTermFFI.newTerminal(self.vt_lib, view.rows, view.cols)
    self.vt = vt
    self.screen = screen
    view.vt = vt
    view.screen = screen
    view.vt_lib = self.vt_lib

    -- 5. 挂接 damage 脏矩形与光标更新
    self._damage_cb = ffi.cast("damage_flat_fn", function(start_row, end_row, start_col, end_col, user)
        if self.view then
            self.view:setDirtyRegion(start_row, end_row)
        end
        return 1
    end)
    self._movecursor_cb = ffi.cast("movecursor_flat_fn", function(row, col, old_row, old_col, visible, user)
        if self.view then
            -- 不脏整行: 只刷新旧光标格窄条(墨水屏防频闪, 见 vterm_view.cursorMoved)
            self.view:cursorMoved(old_row, old_col, row, col)
        end
        return 1
    end)

    self._bridge_cb = ffi.new("VTermBridgeCallbacks")
    self._bridge_cb.damage = self._damage_cb
    self._bridge_cb.movecursor = self._movecursor_cb
    self._bridge_cb.bell = nil
    self._bridge_cb.user = nil
    self.vt_lib.vterm_bridge_set_callbacks(screen, self._bridge_cb)

    -- 5b. 本地滚动历史(↑/↓ 在 Scrollback 开关打开时翻历史)
    -- 注意 vterm_bridge_set_scrollhooks 会重设整张 callbacks 表, 所以它必须
    -- 在 set_callbacks 之后调用, 且内部会一并挂回 damage/movecursor。
    -- 对象挂 self 上: dialog 重建后 _reattachVTerm 原样重挂(cols 不变, 栈不受行数影响)。
    self._vt_sb = Scrollback.new(self.vt_lib, vt, screen, view.rows, view.cols,
        G_reader_settings:readSetting("vterm_sb_lines")):install()
    view._vt_sb = self._vt_sb

    -- 6. 派生 PTY 子进程
    local cur_path = os.getenv("PATH") or "/bin:/usr/bin"
    local plugin_bin = self.path .. "/bin"
    local locale_dir = self.path .. "/locale"
    local env_vars = {
        PLUGIN_DIR = self.path,
        PATH = plugin_bin .. ":" .. cur_path,
        -- LOCPATH 指向插件自带的编译产物(Kindle 系统无任何 UTF-8 locale,
        -- bash readline 无多字节模式 → 中文按字节处理: 回显 ?、退格撕裂)。
        -- locale/zh_CN.utf8 由 localedef 在设备上编译一次(见 ensureLocale)。
        LOCPATH = locale_dir,
        LANG = "zh_CN.utf8",
        LC_ALL = "zh_CN.utf8",
        TERM = "xterm-256color",
        -- Kindle 系统 terminfo 无 xterm 系列 → clear/less/tput 等报
        -- "unknown terminal type"; 插件自带编译条目(terminfo/x/),
        -- TERMINFO 指过去即可。远程会话不受影响(远端用自己的库)。
        TERMINFO = self.path .. "/terminfo",
        -- [V] 为 pty.lua 行模式检测标记(回车失效/提示符激活, 区分 shell 行与 vi 全屏态)
        PS1 = "\\w [V]\\$ ",
    }

    local pty = PTY.new()
    pty.is_local = (session.type ~= "ssh") -- 标记本地会话，开启内核回显精准去问号
    -- 编辑器退格语义: bin/vim(bin/vi) 包装启动时写 editor.kind —
    -- "wide"=字符级(utf8 vim, 1 个退格删 1 字), "byte"/缺省=字节级
    -- (busybox vi, 每字节 1 个退格)。运行时探测不可靠(movecursor 被
    -- bridge 合并、回显结构因程序而异), 包装身份最确定。
    if pty.is_local then
        local kf = io.open(self.path .. "/bin/editor.kind", "r")
        if kf then
            pty.byte_level_editor = not kf:read("*a"):match("wide")
            kf:close()
        end -- 无文件: nil → delChar 保守按字节级
    end
    local ok, pid = pty:spawn(cmd, args, view.rows, view.cols, env_vars)
    if not ok then
        print("[VTerm] Failed to spawn PTY: " .. tostring(pid))
        return
    end
    self.pty = pty
    view.pty = pty
    self._vt_local_session = (session.type ~= "ssh")

    -- 原生 shell 透传: 本地会话解析到插件 Unicode busybox(见
    -- buildLaunchCommand 的 ARM 升级)时, 行编辑回显已是真 UTF-8 且宽列正确,
    -- pty 侧全部抑制/翻译/还原层关闭。插件目录放 native.off 可强制回退旧路径。
    if pty.is_local and cmd and cmd:find("/bin/busybox$", 1, false) then
        local noff = io.open(self.path .. "/native.off", "r")
        if noff then
            noff:close()
        else
            pty.native_shell = true
        end
    end

    -- 记录子进程 pid: 异常退出(KOReader 崩溃)后由 init 收割(见 reapStale)
    do
        local pf = io.open(self.path .. "/terminal.pid", "w")
        if pf then pf:write(tostring(pid)) pf:close() end
    end

    -- 本地 shell: 注入 ls UTF-8 包装(Kindle busybox ls 编译未开 Unicode,
    -- 会把中文文件名显示为 ?; ls_utf8.sh 用 find 原样输出字节替代)
    -- 必须在 shell 打出首个提示符之后再写: bash 就绪前写入的字节由 tty
    -- 回显, 真机上会看到整屏重复的 source 行且命令不执行(模拟器启动快,
    -- 一直没暴露)。
    -- native 透传时 shell 就是插件 busybox: bin/ls 包装(Unicode ls)经 PATH
    -- 直接生效, 无需再注入 ls_utf8.sh。
    if session.type ~= "ssh" and not (self.pty and self.pty.native_shell) then
        -- 真机 /bin/sh 是 busybox, 没有 source 内建(旧代码在真机上整行回显且
        -- 不执行), 因此用 POSIX 的 `.`。
        -- 必须拆成两条短命令: 真机 bash 对超过一屏宽的行会在 readline 里
        -- 反复折行重绘, 屏幕上留下十几行同样的命令副本(命令本身只执行一次,
        -- 见 echo.log)。先建软链, 提示符回来后再点号加载。
        local sh = self.path .. "/bin/ls_utf8.sh"
        if sh:find("^/") then
            self._vt_shortcut_cmd = 'ln -sf "' .. sh .. '" /tmp/vt_ls'
        else
            -- self.path 是相对的("plugins/vterm.koplugin"), 用 $PWD 拼绝对路径
            self._vt_shortcut_cmd = 'ln -sf "$PWD/' .. sh .. '" /tmp/vt_ls'
        end
        local step = 0
        local function injectWhenReady()
            if not self.pty then return end
            if not self.pty:lineActive() and step < 40 then
                step = step + 1
                UIManager:scheduleIn(0.1, injectWhenReady)
                return
            end
            self.pty:write(self._vt_shortcut_cmd .. "\n")
            UIManager:scheduleIn(0.6, function()
                if self.pty then self.pty:write(". /tmp/vt_ls\n") end
            end)
        end
        UIManager:scheduleIn(0.1, injectWhenReady)
    end

    -- PTY 写入 + 立即回读刷新闭环(逻辑在 _ptyWriteRoundtrip, 重建后 reattach 重挂)
    view._vt_write = function(data)
        self:_ptyWriteRoundtrip(data)
    end
    -- 布局切换(条带高度变化)引发 rows 变化时, 视图回调同步网格/PTY 尺寸
    view._vt_resize_cb = function() self:_applyTerminalSize() end
    self._vt_grid_dims = { rows = view.rows, cols = view.cols }

    -- 7. 显示终端对话框并唤起键盘
    UIManager:show(self.dialog)
    self.dialog:onShowKeyboard(true)
    -- 键盘首绘兜底: PTY 首批输出的局部 fast 刷新可能与键盘初次绘制抢刷,
    -- 左上角会残留未刷区域(切布局才恢复)。1s 后全屏刷新一次补全。
    UIManager:scheduleIn(1, function()
        if self.dialog then UIManager:setDirty(self.dialog, "full") end
    end)

    -- 8. 启动后台 PTY 输出轮询
    self:schedulePtyRead()
end

function VTermPlugin:schedulePtyRead()
    if not self.pty or not self.pty:isAlive() then
        -- shell 已退出(用户敲 exit / SSH 断开): 排干尾部输出后自动关闭。
        -- 插件无重连逻辑, 旧行为是静默卡屏。
        if self.pty then
            local chunk = self.pty:read()
            if chunk and #chunk > 0 then
                self:_feedVterm(chunk)
            end
            UIManager:scheduleIn(0.3, function()
                self:closeTerminal()
            end)
        end
        return
    end

    local chunk = self.pty:read()
    if chunk and #chunk > 0 then
        self._vt_idle_reads = 0
        self:_feedVterm(chunk)
    else
        self._vt_idle_reads = (self._vt_idle_reads or 0) + 1
    end

    -- 空闲退避省电(指数): 有数据 10ms; 之后 50/100/200/500ms→1s 封顶;
    -- 数据一到即回 10ms。交互回显走 _ptyWriteRoundtrip 不经此轮询,
    -- 退避只影响远端主动推送的首包延迟, 1s 无感。真机实测: 空闲会话
    -- 旧逻辑烧 7~11% CPU(keepalive 重置退避), 新逻辑 <1%。
    local idle = self._vt_idle_reads or 0
    local delay = 0.01
    if idle > 400 then
        delay = 1.0
    elseif idle > 250 then
        delay = 0.5
    elseif idle > 120 then
        delay = 0.2
    elseif idle > 50 then
        delay = 0.1
    elseif idle > 30 then
        delay = 0.05
    end
    UIManager:scheduleIn(delay, function()
        self:schedulePtyRead()
    end)
end

-- 绝对列坐标换算: busybox vi 按**字节**计列(一个汉字 = 3 列), 而 libvterm 一个
-- 汉字占 2 格 → 它每打完一个字就发 `ESC[r;cH` 把光标挪到"字节列", 屏幕上
-- 表现为每个汉字后多出一格空格(甚至整行内容被推出屏外)。
-- 做法 = 重放式影子模型: 逐字节跟踪 vi 逻辑里的"字节列/显示列", 遇到纯 CUP
-- 序列(ESC[r;cH)时按 显示列 = 字节列 - 本行已走过的宽字数 改写列号。
-- 只在本地会话 + 非 shell 行(vi 等全屏应用)启用; 其它序列原样透传。
-- 行状态在 CR / 换行 / 清屏 / 切备用屏时重置。

local WIDE_SLACK = 6 -- 宽字判定窗口上限(够覆盖 emoji 序列)

function VTermPlugin:_resetColModel(row)
    self._col_row = row      -- 当前跟踪的行(0 起; -1 = 未知)
    self._col_byte = 0       -- 该行 vi 逻辑字节列
    self._col_wide = 0       -- 该行已走过的宽字符数
end

-- 把 chunk 里的 CUP 列号从"字节列"换算成"显示列"
function VTermPlugin:_fixByteColumns(chunk)
    local out = {}
    local pos, len = 1, #chunk
    local state = self.vt_lib.vterm_obtain_state(self.vt)
    local cur = ffi.new("VTermPos")
    self.vt_lib.vterm_state_get_cursorpos(state, cur)
    if self._col_row ~= cur.row then
        -- 行不同步(被别的路径移动过): 以 libvterm 当前光标为准重新对齐
        self._col_row = cur.row
        self._col_byte = cur.col
        self._col_wide = 0
    end
    while pos <= len do
        local b = chunk:byte(pos)
        if b == 27 then
            local s_start = pos
            local e = pos + 2
            while e <= len do
                local cb = chunk:byte(e)
                if cb >= 0x40 and cb <= 0x7E then break end
                e = e + 1
            end
            if e > len then
                self._csi_carry = chunk:sub(s_start)
                break
            end
            local params, final = chunk:sub(s_start + 2, e - 1), chunk:sub(e, e)
            local row_s, col_s = params:match("^(%d*);(%d*)$")
            if final == "H" and row_s then
                local row = tonumber(row_s) or 1
                local col = tonumber(col_s) or 1
                if row - 1 ~= self._col_row then
                    self._col_row = row - 1
                    self._col_wide = 0
                end
                local newcol = math.max(1, col - self._col_wide)
                self._col_byte = col - 1
                out[#out + 1] = string.format(string.char(27) .. "[%d;%dH", row, newcol)
            else
                out[#out + 1] = chunk:sub(s_start, e)
            end
            pos = e + 1
        elseif b == 13 then
            self._col_byte, self._col_wide = 0, 0
            out[#out + 1] = string.char(b)
            pos = pos + 1
        elseif b == 10 then
            self._col_row = self._col_row + 1
            self._col_byte, self._col_wide = 0, 0
            out[#out + 1] = string.char(b)
            pos = pos + 1
        elseif b == 8 then
            self._col_byte = math.max(0, self._col_byte - 1)
            out[#out + 1] = string.char(b)
            pos = pos + 1
        elseif b < 32 then
            out[#out + 1] = string.char(b) -- 其它控制字符不影响列模型
            pos = pos + 1
        else
            -- 可见字符: 按字节推进逻辑列, 识别整字后统计是否宽字符
            local blen = 1
            if b >= 0xF0 then blen = 4
            elseif b >= 0xE0 then blen = 3
            elseif b >= 0xC0 then blen = 2 end
            if pos + blen - 1 <= len then
                if blen > 1 then
                    self._col_wide = self._col_wide + 1
                end
                self._col_byte = self._col_byte + blen
                out[#out + 1] = chunk:sub(pos, pos + blen - 1)
                pos = pos + blen
            else
                out[#out + 1] = chunk:sub(pos)
                break
            end
        end
    end
    return table.concat(out)
end

-- 喂入 libvterm: 本地全屏应用先做列坐标换算, 其余原样。
-- 字节列→显示列换算只为字节级编辑器(busybox vi: 光标序列按 UTF-8 字节数
-- 前进); 宽字符编辑器(探测 byte_level_editor=false, 如 utf8 vim)发的已是
-- 显示列, 再换算会把 [1;7H 压小 → [K 清掉半行汉字(现象: vim 内删 1 个
-- 汉字, 屏上前面的字也消失)。未探测(纯 ASCII 流)时维持旧行为(无害)。
function VTermPlugin:_feedVterm(chunk)
    if self._vt_local_session and self.pty and not self.pty:lineActive()
        and self.pty.byte_level_editor ~= false then
        local carried = self._csi_carry
        self._csi_carry = nil
        if carried then chunk = carried .. chunk end
        chunk = self:_fixByteColumns(chunk)
    else
        self._csi_carry = nil
    end
    if #chunk > 0 then
        self.vt_lib.vterm_input_write(self.vt, chunk, #chunk)
        self.vt_lib.vterm_screen_flush_damage(self.screen)
    end
end

-- ==================== VTERM_AUTOTEST=4: 中英输入/删除组合回归套件 ====================
-- 真机全链路: addChars/delChar → PTY → 内核回显 → libvterm → 屏上格子断言。
-- 断言结果落盘 autotest.log, 由外部脚本拉回判定。
local function cp2utf8(cp)
    if cp < 128 then return string.char(cp)
    elseif cp < 2048 then return string.char(192 + math.floor(cp / 64), 128 + cp % 64)
    elseif cp < 65536 then
        return string.char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64)
    end
    return string.char(240 + math.floor(cp / 262144), 128 + math.floor(cp / 4096) % 64,
        128 + math.floor(cp / 64) % 64, 128 + cp % 64)
end

function VTermPlugin:_suiteLog(s)
    local f = io.open(self.path .. "/autotest.log", "a")
    if f then f:write(s, "\n") f:close() end
    -- 真机一次性测试开关: 任一 suite 收尾即撤掉, 下次启动恢复正常
    if s:find("SUITE DONE", 1, true) then os.remove(self.path .. "/imetest.on") end
end

-- 收键盘后清残影: fullscreen 布局用不画像素的 VerticalSpan 给键盘占位,
-- VK close 后 bb 上键盘像素没有任何 widget 覆盖重画(VK 自己的 setDirty
-- 挂在已出栈 widget 上, 不触发重绘) → 屏上键盘残影原样留着。
-- 手动把键盘区域刷成背景色, 再按 region 排一次刷新。
function VTermPlugin:_paintOutKeyboard(v)
    return pcall(function()
        local kb = v and v.keyboard
        if not kb then return end
        local ksz = kb.getSize and kb:getSize()
        if not ksz or not ksz.h or ksz.h <= 0 then return end
        local Screen = Device.screen
        local d = require("ui/geometry"):new{
            x = 0,
            y = Screen:getHeight() - ksz.h,
            w = Screen:getWidth(),
            h = ksz.h,
        }
        Screen.bb:paintRect(d.x, d.y, d.w, d.h, Blitbuffer.COLOR_WHITE)
        UIManager:setDirty(nil, "ui", d)
    end)
end

-- PTY 写入 + 立即回读刷新闭环(由 view 的输入提交规则触发)
function VTermPlugin:_ptyWriteRoundtrip(data)
    if not self.pty then return end
    -- 影子行合成全在 pty 写侧数据驱动(写入字节即 shell 实收字节), 视图无需同步
    self.pty:write(data)
    local chunk = self.pty:read()
    if chunk and #chunk > 0 then
        self:_feedVterm(chunk)
    end
end

-- ==================== 终端设置(字号/历史行数) ====================
-- 入口在 KOReader 主菜单 VTerm 二级菜单(原生菜单项, 真机点击稳定);
-- 设置弹 SpinWidget(与内置终端同款)。真机实测弹层式菜单点击不可靠, 已弃 ≡ 按钮。

-- ==================== 标题栏电量与时间 ====================
-- TitleBar 右对齐(Noto Sans Regular 20 号, 右侧留 20px 空白)。省电策略:
-- 分钟对齐单次唤醒(不轮询)、文本未变不刷新、仅标题条小区域 fast、
-- 会话关闭/功能关闭自动停链。可在"⚙ 设置"对话框勾选开关。

function VTermPlugin:_titleInfoEnabled()
    return G_reader_settings:readSetting("vterm_title_info") ~= false
end

-- 把"时间 电量"TextWidget 挂进 TitleBar 的标题行(右对齐, Noto Sans 20 号)
function VTermPlugin:_patchTitleBar()
    local tb = self.dialog and self.dialog.title_bar
    if not tb or not tb.title_widget or rawget(tb, "_vt_info") then return end
    -- 点击标题栏 = 全屏刷新(清 e-ink 残影)。插在 OverlapGroup 最底层:
    -- 左图标(返回)在更高层优先接管自己区域, 其余区域落到本层;
    -- 与电量时间开关无关, 关显示后点击刷新仍可用。
    if not rawget(tb, "_vt_tap") then
        local InputContainer = require("ui/widget/container/inputcontainer")
        local GestureRange = require("ui/gesturerange")
        local tap = InputContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = tb.width or 0, h = tb.titlebar_height or 40 },
        }
        tap.ges_events = {
            TapTitleRefresh = { GestureRange:new{ ges = "tap", range = tap.dimen } },
        }
        tap.onTapTitleRefresh = function()
            UIManager:setDirty(nil, "full") -- 全屏黑闪刷新
            return true
        end
        table.insert(tb, 1, tap) -- OverlapGroup 首位 = 最底层
        tb._vt_tap = tap
    end
    if not self:_titleInfoEnabled() then return end
    local TextWidget = require("ui/widget/textwidget")
    local VerticalSpan = require("ui/widget/verticalspan")
    local RightContainer = require("ui/widget/container/rightcontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local Font = require("ui/font")
    -- 固定字体: Noto Sans Regular(细线感), 逻辑字号 20(getFace 内部再做 DPI 缩放)
    local info_face = Font:getFace("NotoSans-Regular.ttf", 20)
        or Font:getFace("cfont", 20) or tb.title_widget.face
    -- 先给代表文本量高(空文本 getSize 高度为 0), 真实文本由 _updateTitleInfo 设置
    local info = TextWidget:new{ text = "00:00", face = info_face, padding = 0 }
    -- TitleBar 是 OverlapGroup(子元素重叠): 直插右对齐容器即靠右;
    -- 沿用 top_padding 对齐标题文本顶部, 再按字号高度差垂直居中;
    -- RightContainer 宽度减 20 = 右侧留 20px 空白
    local top_pad = tb.title_group[1] and tb.title_group[1].width or 0
    local title_h = tb.title_widget:getSize().h
    local info_h = info:getSize().h
    if title_h > info_h then top_pad = top_pad + math.floor((title_h - info_h) / 2) end
    local holder = VerticalGroup:new{
        align = "right",
        VerticalSpan:new{ width = top_pad },
        info,
    }
    local rc = RightContainer:new{
        dimen = Geom:new{ w = math.max(0, (tb.width or 0) - 20), h = tb.titlebar_height or 40 },
        holder,
    }
    table.insert(tb, rc) -- OverlapGroup 追加子元素 = 叠加绘制
    tb._vt_info = info
    tb._vt_rc = rc
    self._title_info = info
    self._title_rc = rc
    self:_updateTitleInfo(true)
end

-- 每分钟对齐刷新: 时间+电量(充电加 + 号); 文本未变则只排下一分钟
function VTermPlugin:_updateTitleInfo(force)
    if not (self.dialog and self._title_info and self:_titleInfoEnabled()) then return end
    local cap, chg, chged = 0, false, false
    pcall(function()
        local pm = Device:getPowerDevice()
        cap = tonumber(pm:getCapacity()) or 0
        chg = pm:isCharging() and true or false
        chged = pm:isCharged() and true or false
    end)
    -- 电量图标: powerd 官方字形(U+E778+, 经全局字体回退链 nerdfonts/symbols.ttf
    -- 渲染), 与 KOReader 页脚状态栏同源同风格
    local symbol = ""
    pcall(function()
        symbol = Device:getPowerDevice():getBatterySymbol(chged, chg, cap) or ""
    end)
    -- 与原生菜单同格式(touchmenu.lua): 时间 + " " + ⌁(U+2301 电波符) + 电池字形 + 百分比
    local txt = os.date("%H:%M") .. " ⌁" .. symbol .. tostring(cap) .. "%"
    local info = self._title_info
    if force or txt ~= info.text then
        info:setText(txt)
        -- 只刷标题条小区域(fast, 省电)
        local tb = self.dialog.title_bar
        UIManager:setDirty(self.dialog, "fast", Geom:new{
            x = 0, y = 0,
            w = self.dialog.width or 0,
            h = (tb.titlebar_height or 40) + 10,
        })
    end
    -- 分钟对齐: 下一分钟的 :01 唤醒(每小时 60 次小区域刷新, 无轮询空转)。
    -- _title_tick_pending 防重入: reattach/force 调用不与在途链双开。
    if not self._title_tick_pending then
        self._title_tick_pending = true
        local seq = self._title_seq
        local nxt = 61 - tonumber(os.date("%S"))
        UIManager:scheduleIn(nxt, function()
            self._title_tick_pending = false
            if seq == self._title_seq then self:_updateTitleInfo() end
        end)
    end
end

-- 关闭显示/会话结束: 摘除信息组件 + 停刷新链
-- (标题栏点击刷新层 _vt_tap 与显示开关解耦, 常驻到对话框销毁, 不在此摘)
function VTermPlugin:_stopTitleInfo()
    self._title_seq = (self._title_seq or 0) + 1
    local tb = self.dialog and self.dialog.title_bar
    if tb and rawget(tb, "_vt_rc") then
        for i = #tb, 1, -1 do
            if tb[i] == tb._vt_rc then table.remove(tb, i) end
        end
        tb._vt_rc:free()
        tb._vt_rc = nil
        tb._vt_info = nil
    end
    self._title_info = nil
    self._title_rc = nil
    if self.dialog then UIManager:setDirty(self.dialog, "ui") end
end

function VTermPlugin:_closeHostMenu()
    if self.ui and self.ui.menu then pcall(function() self.ui.menu:onClose() end) end
end

function VTermPlugin:showSettings()
    self:_closeHostMenu()
    local DoubleSpinWidget = require("ui/widget/doublespinwidget")
    local CheckButton = require("ui/widget/checkbutton")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Size = require("ui/size")
    local dlg
    dlg = DoubleSpinWidget:new{
        title_text = _("终端设置"),
        left_text = _("字体大小"),
        left_min = 8, left_max = 30, left_value = G_reader_settings:readSetting("vterm_font_size") or 18,
        left_default = 18,
        right_text = _("历史行数"),
        right_min = 500, right_max = 5000,
        right_value = G_reader_settings:readSetting("vterm_sb_lines") or 2000,
        right_precision = "%d",
        right_default = 2000,
        default_text = _("恢复默认"),
        ok_text = _("应用"),
        callback = function(font_size, sb_lines)
            local cur_fs = G_reader_settings:readSetting("vterm_font_size") or 18
            G_reader_settings:saveSetting("vterm_font_size", font_size)
            G_reader_settings:saveSetting("vterm_sb_lines", sb_lines)
            if self._vt_sb then self._vt_sb.max_lines = sb_lines end
            if font_size ~= cur_fs then
                self:_changeFontSize(font_size) -- 终端开着则热切换(未开时下次生效)
            end
            if dlg._vt_title_pending ~= nil then -- 点应用才保存标题栏开关
                G_reader_settings:saveSetting("vterm_title_info", dlg._vt_title_pending)
                if self.dialog then -- 终端开着: 即时生效
                    if dlg._vt_title_pending then self:_patchTitleBar() else self:_stopTitleInfo() end
                end
                dlg._vt_title_pending = nil
            end
        end,
    }
    -- "标题栏电量与时间"勾选行, 插在按钮排上方。DoubleSpinWidget 每次选值
    -- 都会 update() 整体重建布局 → 包一层 update, 每次重建后重插勾选行。
    -- 应用键使能 = 选值有变更(官方) 或 勾选有待定态(这里手动点亮)
    local function setOkEnabled(d, enable)
        local bt = d.widget_frame and d.widget_frame[1]
        bt = bt and bt[4] and bt[4][1] -- [4]=CenterContainer → [1]=ButtonTable
        if not bt or not bt.buttons_layout then return end
        local last = bt.buttons_layout[#bt.buttons_layout]
        local ok = last[#last]
        if ok and ok.enable then
            if enable then ok:enable() else ok:disable() end
            -- Button:enable/disable 只改字段/字色, 不自带刷新 → 手动补脏区
            if ok.dimen then UIManager:setDirty(d, "ui", ok.dimen) end
        end
    end
    local function addTitleInfoToggle(d)
        local vg = d.widget_frame and d.widget_frame[1]
        if not vg or rawget(d, "_vt_cb") then return end
        local text = _("标题栏显示电量与时间")
        local TextWidget = require("ui/widget/textwidget")
        local tw = TextWidget:new{ text = text, face = CheckButton.face }
        local text_w = tw:getSize().w
        tw:free()
        local cb -- 先声明再赋值: 闭包内引用 cb, 若写在同一条 local 语句里会绑到全局 nil
        cb = CheckButton:new{
            text = text,
            -- spinner 重建之间保住未应用的待定态(否则改字号时勾选会被打回已存值)
            checked = d._vt_title_pending ~= nil and d._vt_title_pending
                or self:_titleInfoEnabled(),
            width = d.width - 2 * Size.padding.default,
            parent = d, -- toggleCheck 的 setDirty 目标
            callback = function() -- 只记待定态, 点"应用"才保存(dlg callback)
                d._vt_title_pending = cb.checked and true or false
                setOkEnabled(d, true) -- 有待定态: 点亮应用键
            end,
        }
        -- 收窄到内容实际宽度(勾框+文本+左右各一格内边距), CenterContainer 才能真居中
        cb.width = cb._checkmark.dimen.w + text_w + 2 * Size.padding.default
        cb:initCheckButton(cb.checked) -- 按新宽度重建内部布局
        local row = CenterContainer:new{
            dimen = Geom:new{ w = d.width, h = cb.dimen.h },
            cb,
        }
        table.insert(vg, 3, row) -- [1]=标题栏 [2]=选值区 [3]=按钮排 → 插到按钮排前
        if vg.resetLayout then vg:resetLayout() end -- VerticalGroup 结构手术必做
        d._vt_cb = cb
        if d._vt_title_pending ~= nil then
            setOkEnabled(d, true) -- 重建后待定态仍在: 保持应用键点亮
        end
    end
    addTitleInfoToggle(dlg)
    local orig_update = dlg.update
    dlg.update = function(dself, l, r)
        orig_update(dself, l, r)
        dself._vt_cb = nil -- 重建后旧引用作废
        addTitleInfoToggle(dself)
    end
    UIManager:show(dlg)
end
-- 字号热切换: 只重建对话框(新字形度量→新 rows/cols), PTY/vt 会话原样保留
function VTermPlugin:_changeFontSize(size)
    G_reader_settings:saveSetting("vterm_font_size", size)
    if not self.dialog then return end -- 终端未开: 下次打开生效
    local oldv = self.view
    self._vt_prev_grid = oldv and { rows = oldv.rows, cols = oldv.cols }
    UIManager:close(self.dialog)
    self.dialog = nil
    self.view = nil
    self:startTerminal(self._vt_session, { reuse = true })
end

-- ⌨ 软键盘+按钮栏同步收放: 走 InputDialog:toggleKeyboard 官方重建路径
-- (布局真正重排, 键盘/按钮栏空间让给终端网格), 重建后必须重挂终端状态。
function VTermPlugin:_toggleKeyboardBar()
    if not self.dialog then return end
    if self.view and self.view._gesLog then
        self.view:_gesLog("KBTOGGLE kb=" .. tostring(self.dialog:isKeyboardVisible()))
    end
    self.dialog:toggleKeyboard()
    self:_reattachVTerm()
end

-- dialog:toggleKeyboard/reinit 会重建整棵对话框树: 新 VTermView 实例、新
-- ButtonTable、新 VirtualKeyboard。把现有 vt/screen/scrollback/PTY 重新挂上,
-- 行数变化时 resize 终端(TIOCSWINSZ → SIGWINCH → shell 感知新尺寸)。
function VTermPlugin:_reattachVTerm()
    local dlg = self.dialog
    local view = dlg and dlg._input_widget
    if not view or not self.vt then return end
    local old = self.view
    self.view = view
    view._vt_local = (old and old._vt_local) or true
    view._vt_collapsed = not dlg.keyboard_visible
    view._vt_plugin_path = self.path -- 手势实测记录(geslog.on)的开关/日志路径

    -- 按钮引用重抓(ButtonTable 重建了, 旧引用是死按钮)
    local function findBtn(txt)
        local bt = dlg.button_table
        if not bt or not bt.buttons_layout then return nil end
        for _, row in ipairs(bt.buttons_layout) do
            for _, b in ipairs(row) do
                if type(b) == "table" and b.text == txt then return b end
            end
        end
    end
    self._btn_ctrl = findBtn("Ctrl")
    self._btn_arrow = findBtn("⇆")
    self._btn_sb = findBtn("⇕")
    view._vt_ctrl_btn = self._btn_ctrl
    view._vt_on_ctrl_used = function()
        if self._btn_ctrl then self._btn_ctrl:setText("Ctrl", self._btn_ctrl.width) end
        UIManager:setDirty(dlg, "ui")
    end
    view._vt_toggle_cb = function() self:_toggleKeyboardBar() end

    -- 终端状态机与 IO 闭环挂到新 view(仍是同一个 vt/screen/PTY/scrollback)
    view.vt = self.vt
    view.screen = self.screen
    view.vt_lib = self.vt_lib
    view._vt_write = function(data) self:_ptyWriteRoundtrip(data) end
    -- 布局切换(条带高度变化)引发 rows 变化时, 视图回调同步网格/PTY 尺寸
    view._vt_resize_cb = function() self:_applyTerminalSize() end
    view._vt_sb = self._vt_sb
    view._vt_sb_mode = (old and old._vt_sb_mode) or false
    view._vt_ctrl_pending = (old and old._vt_ctrl_pending) or false
    self:_patchTitleBar() -- toggleKeyboard 重建了 title_bar, 重挂时间/电量

    -- ⌨ 收起手术: 摘掉 vgroup 尾部的按钮栏容器, 空间让给终端网格。
    -- (toggleKeyboard 官方重建只重排键盘, 按钮栏是 init 的固定部分;
    --  不能用空 buttons 重建 — 715 行 getButtonById("keyboard") 会崩。)
    -- 手术改 rows 后与键盘 delta 合并成一次 resize。
    if view._vt_collapsed then
        local vg = dlg.vgroup
        local tail = vg and vg[#vg]
        if tail and tail ~= self._btns_container then
            self._btns_container = tail
            self._btns_h = tail:getSize().h
            table.remove(vg)
            view._vt_extra_h = self._btns_h
            -- 容器同步扩高: 包住 view 的 CenterContainer 的 dimen 在 init 时
            -- 按未扩高的 getSize() 定死; 若只虚增 view:getSize(), 容器会把
            -- 变高的子 widget 居中上移 extra/2 像素 → 网格顶部越界压进标题栏
            -- (字号小/行多时明显)。容器长到同高后居中偏移归零。
            local cont = vg[3] -- [1]=title_bar [2]=span [3]=view 容器
            if cont and cont[1] == view and cont.dimen then
                cont.dimen.h = cont.dimen.h + view._vt_extra_h
            end
            view.avail_rows_h = math.max(view.bar_h, view.height + view._vt_extra_h - view.bar_h)
            view.rows = math.max(3, math.floor(view.avail_rows_h / view.cell_h))
            -- ⚠️ VerticalGroup 的 _size/_offsets 是布局缓存, 结构变更后必须
            -- resetLayout, 否则 paintTo 用旧 offsets → 条目错位 → 51 行 nil 崩。
            vg:resetLayout()
        end
        -- 垫底: 手术后 frame 高度变矮, 居中/露底会留下旧帧残影 —— 给 vgroup
        -- 尾部垫一个 span 让 FrameContainer 白背景重新铺满全屏, 盖掉一切旧帧。
        local Screen = Device.screen
        local remain = Screen:getHeight() - vg:getSize().h
        if remain > 0 then
            local VerticalSpan = require("ui/widget/verticalspan")
            self._vt_filler = VerticalSpan:new{ width = Screen:getWidth(), height = remain }
            table.insert(vg, self._vt_filler)
            vg:resetLayout()
        end
    else
        self._btns_container = nil
        self._btns_h = nil
    end

    -- 方向手势开关状态延续(注册到新 view 的 ges_events); 关也要注册——
    -- 上下滑(↑/↓ 或 PgUp/PgDn)的 swipe/pan 处理器在 ⇆关分支里
    view._vt_arrows = (old and old._vt_arrows) or false
    view:setArrowGestures(view._vt_arrows)

    -- 开关按钮显示状态恢复
    if self._btn_arrow then
        self._btn_arrow:setText(view._vt_arrows and "⇆*" or "⇆", self._btn_arrow.width)
    end
    if self._btn_sb then
        self._btn_sb:setText(view._vt_sb_mode and "⇕*" or "⇕", self._btn_sb.width)
    end
    if self._btn_ctrl then
        self._btn_ctrl:setText(view._vt_ctrl_pending and "Ctrl*" or "Ctrl", self._btn_ctrl.width)
    end

    -- 行数/列数变化 → resize 终端 + 通知 PTY(内核给前台进程组发 SIGWINCH)。
    -- _vt_prev_grid: 字号重建路径里 old==view(同实例), 须用重建前的网格尺寸比。
    local prev = self._vt_prev_grid or old
    self._vt_prev_grid = nil
    self:_applyTerminalSize(prev)

    UIManager:setDirty(dlg, "full")
end

-- 网格尺寸同步(libvterm 网格 + PTY winsize + scrollback):
-- 布局切换/字号重建/键盘收放共用; prev_grid 缺省用上次已应用尺寸快照。
function VTermPlugin:_applyTerminalSize(prev_grid, view)
    view = view or self.view
    if not view or view ~= self.view or not self.vt or not self.vt_lib then return end
    local prev = prev_grid or self._vt_grid_dims
    self._vt_grid_dims = { rows = view.rows, cols = view.cols }
    if prev and view.rows == prev.rows and view.cols == prev.cols then return end
    self.vt_lib.vterm_set_size(self.vt, view.rows, view.cols)
    if self.pty then self.pty:setWindowSize(view.rows, view.cols) end
    -- cols 变了: 历史行是按旧列数分配的 cell 数组, 宽度混用会越界读, 清空重开
    if prev and view.cols ~= prev.cols and self._vt_sb then
        self._vt_sb:reset(view.rows, view.cols)
    end
    view:setDirtyRegion(0, view.rows - 1)
end

-- 读取光标所在行(UTF-8 文本)与该行非 ASCII 残留计数
function VTermPlugin:_suiteCursorLine()
    local vt_lib = self.vt_lib
    local state = vt_lib.vterm_obtain_state(self.vt)
    local pos = ffi.new("VTermPos")
    vt_lib.vterm_state_get_cursorpos(state, pos)
    local row, col = pos.row, pos.col
    local cell = ffi.new("VTermScreenCell")
    local text, non_ascii = "", 0
    local c = 0
    while c < self.view.cols do
        pos.row, pos.col = row, c
        vt_lib.vterm_screen_get_cell(self.screen, pos, cell)
        local cp = cell.chars[0]
        local w = tonumber(cell.width) or 1
        if w == 2 and cp ~= 0 and cp ~= 0xFFFFFFFF then
            text = text .. cp2utf8(cp) -- 宽字符: 续格列跳过
            non_ascii = non_ascii + 1
            c = c + 2
        elseif cp ~= 0 and cp ~= 0xFFFFFFFF then
            text = text .. cp2utf8(cp)
            if cp > 127 then non_ascii = non_ascii + 1 end
            c = c + 1
        else
            text = text .. " "
            c = c + 1
        end
    end
    return text, non_ascii, row, col
end

function VTermPlugin:_runComboSuite()
    local t = 3.2 -- startTerminal@3s, 留 0.2s spawn 余量; 之后逐步推进
    local function at(dt, fn)
        t = t + dt
        UIManager:scheduleIn(t, function()
            if self.pty and self.pty:isAlive() then fn() end
        end)
    end
    local check_id = 0
    local function check(name, fn, delay)
        check_id = check_id + 1
        local id = check_id
        at(delay or 0.05, function()
            local ok, detail = pcall(fn)
            self:_suiteLog(("CHECK%02d %s: %s | %s"):format(id, name, ok and "PASS" or "FAIL", tostring(detail)))
        end)
    end
    local view = function() return self.view end
    local function screenAll()
        local cell, pos = ffi.new("VTermScreenCell"), ffi.new("VTermPos")
        local all = ""
        for r = 0, self.view.rows - 1 do
            local c = 0
            while c < self.view.cols do
                pos.row, pos.col = r, c
                self.vt_lib.vterm_screen_get_cell(self.screen, pos, cell)
                local cp = cell.chars[0]
                if cp >= 32 and cp < 0x10FFFF and cp ~= 0xFFFFFFFF then
                    all = all .. cp2utf8(cp)
                end
                if tonumber(cell.width) == 2 then c = c + 2 else c = c + 1 end
            end
            all = all .. "\n"
        end
        return all
    end

    at(0.1, function() -- t=3.3: prompt 已就绪
        local f = io.open(self.path .. "/autotest.log", "w")
        if f then f:write("SUITE START ", os.date("%H:%M:%S"), "\n") f:close() end
    end)

    -- T0 dump 子进程环境 + shell/locale 身份 + termios
    at(0.2, function() view():addChars("env >/tmp/childenv; { locale; stty -a; ps w; grep -E 'Sig' /proc/self/status; } >/tmp/child2 2>&1; echo DONE0\n") end)
    at(2.5, function() end)

    -- T1 输入中文
    at(1.0, function() view():addChars("好卡") end) -- t=4.6
    check("T1 输入好卡→屏上出现", function()
        local text = self:_suiteCursorLine()
        assert(text:find("好卡", 1, true), "行=" .. text)
        return text
    end)

    -- T2 逐字删除×2 → 无残影
    at(0.3, function() view():delChar() end)
    at(0.3, function() view():delChar() end)
    check("T2 删净好卡→零非ASCII残留", function()
        local text, non_ascii = self:_suiteCursorLine()
        assert(non_ascii == 0, "残留" .. non_ascii .. "列 行=" .. text)
        return "ok"
    end)

    -- T3 混排输入
    at(0.3, function() view():addChars("ab好cd卡") end)
    check("T3 混排ab好cd卡→屏上正确", function()
        local text = self:_suiteCursorLine()
        assert(text:find("ab好cd卡", 1, true), "行=" .. text)
        return text
    end)

    -- T4 删2次(删 卡,d)
    at(0.3, function() view():delChar() end)
    at(0.3, function() view():delChar() end)
    check("T4 删卡,d→剩ab好c", function()
        local text, non_ascii = self:_suiteCursorLine()
        assert(text:find("ab好c ", 1, true), "行=" .. text)
        return "non_ascii=" .. non_ascii
    end)

    -- T5 删除后继续输入(光标连续性)
    at(0.3, function() view():addChars("ef") end)
    check("T5 续输ef→ab好cef", function()
        local text = self:_suiteCursorLine()
        assert(text:find("ab好cef", 1, true), "行=" .. text)
        return text
    end)

    -- T6 回车执行 → 报错含完整中文命令名(数据层完整)
    at(0.5, function() view():addChars("\n") end)
    check("T6 回车→not found含好字", function()
        local all = screenAll()
        -- bash 报错随 locale 变化: C=not found / zh=未找到命令, 两者都认
        assert(all:find("not found", 1, true) or all:find("未找到命令", 1, true),
            "无报错行:\n" .. all)
        assert(all:find("好", 1, true), "报错缺中文名:\n" .. all)
        return "found"
end, 0.4)

    -- T7/T8 输入你好→删3次(多删)→无残留无崩溃
    at(1.0, function() view():addChars("你好") end)
    check("T7 输入你好→屏上出现", function()
        local text = self:_suiteCursorLine()
        assert(text:find("你好", 1, true), "行=" .. text)
        return text
    end)
    at(0.3, function() view():delChar() end)
    at(0.3, function() view():delChar() end)
    at(0.3, function() view():delChar() end) -- 多删一次
    check("T8 删3次→零残留", function()
        local text, non_ascii = self:_suiteCursorLine()
        assert(non_ascii == 0, "残留" .. non_ascii .. "列 行=" .. text)
        return "ok"
    end)

    -- T9 空行 delChar 不泄漏
    at(0.3, function() view():delChar() end)
    check("T9 空行delChar→行仍干净", function()
        local text, non_ascii = self:_suiteCursorLine()
        assert(non_ascii == 0, "泄漏残留 行=" .. text)
        return "ok"
    end)

    -- T10 中文+回车直达(数据层中文完整性)
    at(0.3, function() view():addChars("测试\n") end)
    check("T10 回车→not found含测试", function()
        local all = screenAll()
        assert((all:find("not found", 1, true) or all:find("未找到命令", 1, true))
            and all:find("测试", 1, true), "屏:\n" .. all)
        return "found"
end, 0.4)

    -- T11 中文命令入历史 → 上键回溯 → 屏上应还原真实汉字(非 ??)
    at(0.3, function() view():addChars("历史测试\n") end)
    at(0.8, function() view():upLine() end)
    check("T11 上键回溯中文命令→汉字还原", function()
        local text = self:_suiteCursorLine()
        assert(text:find("历史测试", 1, true), "行=" .. text)
        assert(not text:find("??", 1, true), "问号残留 行=" .. text)
        return text
    end)

    -- T12 再按一次上键 → 回溯到更早的历史命令, 仍须还原真实汉字非 ??
    -- (历史只记回车时行内实际存在的字符, 具体哪一条取决于套件输入序列)
    at(0.8, function() view():upLine() end)
    check("T12 再上键→更早历史仍是汉字", function()
        local text = self:_suiteCursorLine()
        assert(not text:find("??", 1, true), "问号残留 行=" .. text)
        local hit = false
        for _, cmd in ipairs({ "历史测试", "测试", "ab好cef", "你好" }) do
            if text:find(cmd, 1, true) then hit = true break end
        end
        assert(hit, "未见历史命令 行=" .. text)
        return text
    end)

    -- T13 中文后输入 ASCII '?' → 问号必须原样保留。
    -- 回归点: 还原队列在真实 UTF-8 回显下若不出队, 会把随后的 '?' 顶成汉字
    at(0.3, function() view():delToStartOfLine() end) -- 清掉 T12 回溯出的行
    at(0.5, function() view():addChars("测试") end)
    at(0.4, function() view():addChars("?") end)
    check("T13 中文后输入?→问号保留", function()
        local text = self:_suiteCursorLine()
        assert(text:find("测试?", 1, true), "行=" .. text)
        return text
    end)

    -- T14 历史回溯后按退格 → 末位汉字整字删净(行字符栈须按历史命令重建)
    at(0.4, function() view():addChars("\n") end)
    at(0.5, function() view():addChars("历史二") end)
    at(0.5, function() view():addChars("\n") end)
    at(0.8, function() view():upLine() end)
    at(0.5, function() view():delChar() end)
    check("T14 回溯后删末字→宽字符删净", function()
        local text, non_ascii = self:_suiteCursorLine()
        assert(text:find("历史", 1, true), "行=" .. text)
        assert(not text:find("二", 1, true), "二残留 行=" .. text)
        return "non_ascii=" .. non_ascii
    end)

    -- T15 中文后 ← 再连打两字 → 行中插入模型: X/Y 依次插在光标处(shell 同步),
    -- 镜像=你XY好。回归点: 旧行尾对齐模型会得 你好XY, 直通追加模型会错位乱码
    local t15_pos, t15_sent = nil, nil
    at(0.4, function() view():addChars("你好") end)
    at(0.4, function() view():leftChar() end)
    at(0.4, function() view():addChars("X") end)
    at(0.4, function() view():addChars("Y") end)
    check("T15 中文后←连打XY→行中插入", function()
        local v = view()
        local bar = v._vt_bar_line or ""
        t15_pos, t15_sent = v.charpos, v._vt_sent - (v._vt_line_start or 0)
        return ("bar=%s pos=%s clin=%s n=%s ls=%s sent=%s"):format(bar,
            tostring(v.charpos), tostring(v._vt_sent - (v._vt_line_start or 0)),
            tostring(#v.charlist), tostring(v._vt_line_start), tostring(v._vt_sent))
    end)
    at(0.3, function() view():delChar() end)
    check("T15b 行中退格删Y→镜像你X好", function()
        local v = view()
        local bar = v._vt_bar_line or ""
        assert(bar:find("你X好", 1, true) and not bar:find("你XY", 1, true), "镜像=" .. bar)
        assert((v._vt_sent - (v._vt_line_start or 0)) == t15_sent - 1,
            "sent=" .. tostring(v._vt_sent) .. " 期望=" .. tostring(t15_sent - 1))
        assert(v.charpos == t15_pos - 1, "charpos=" .. tostring(v.charpos))
        return bar
    end)

    -- T16 纯 ASCII 命令回溯: line_active 期 shell 回显被抑制, ↑ 的整行重绘
    -- 全靠写侧历史重建 —— 历史必须记全部命令(旧版只记宽字符 → ASCII 回溯屏上没反应)
    at(0.4, function() view():addChars("\n") end) -- 结束 T15 的输入行
    at(1.0, function() view():addChars("echo ASCIIHIST\n") end)
    at(1.0, function() view():upLine() end)
    check("T16 上键回溯ASCII命令", function()
        local text = self:_suiteCursorLine()
        assert(text:find("echo ASCIIHIST", 1, true), "行=" .. text)
        return text
    end)

    -- T17 再按 ↓ 越过最新一条: shell 回到空行, 合成侧必须同步清行
    at(0.5, function() view():downLine() end)
    check("T17 下键越过最新→空行", function()
        local text, non_ascii = self:_suiteCursorLine()
        assert(not text:find("ASCIIHIST", 1, true), "行=" .. text)
        assert(non_ascii == 0, "残留" .. non_ascii)
        return "empty"
    end)

    -- T18 EN 逐键字母: 真实键盘一次只来一个字母, 必须立刻发出(整串注入测不出)
    at(0.4, function() view():addChars("a") end)
    at(0.4, function() view():addChars("b") end)
    check("T18 EN逐键ab→屏上出现", function()
        local text = self:_suiteCursorLine()
        assert(text:find("ab", 1, true), "行=" .. text)
        return text
    end)
    at(0.4, function() view():delToStartOfLine() end)

    -- T19 ↑/↓ 混合回溯(两条 ASCII + 交错): ↑=def456, 再↑=echo ASCIIHIST,
    -- ↓=回到 def456 (T16 的命令是套件里最近的一条 ASCII)
    at(0.4, function() view():addChars("def456\n") end)
    at(0.8, function() view():upLine() end)
    at(0.4, function() view():upLine() end)
    check("T19 上×2→更早命令echo ASCIIHIST", function()
        local text = self:_suiteCursorLine()
        assert(text:find("echo ASCIIHIST", 1, true), "行=" .. text)
        return text
    end)
    at(0.5, function() view():downLine() end)
    check("T20 下×1→回def456", function()
        local text = self:_suiteCursorLine()
        assert(text:find("def456", 1, true), "行=" .. text)
        return text
    end)
    at(0.5, function() view():downLine() end)
    check("T21 下×2→空行", function()
        local text = self:_suiteCursorLine()
        assert(not text:find("def456", 1, true), "行=" .. text)
        return "empty"
    end)
    at(0.4, function() view():delToStartOfLine() end)

    at(0.5, function() self:_suiteLog("SUITE DONE") end)
end

-- ==================== VTERM_AUTOTEST=11: zh 默认进终端→切 en→英文可输入 ====================
-- 回归用户报障: 进入终端前软键盘默认为中文, 终端内 🌐 切到英文后无法输入。
function VTermPlugin:_runLayoutSwitchSuite()
    local t = 3.2 -- startTerminal@3s
    local function at(dt, fn)
        t = t + dt
        UIManager:scheduleIn(t, function()
            if self.pty and self.pty:isAlive() then fn() end
        end)
    end
    local check_id = 0
    local function check(name, fn)
        check_id = check_id + 1
        local id = check_id
        at(0.05, function()
            local ok, detail = pcall(fn)
            self:_suiteLog(("CHECK%02d %s: %s | %s"):format(id, name, ok and "PASS" or "FAIL", tostring(detail)))
        end)
    end
    local function screenAll()
        local cell, pos = ffi.new("VTermScreenCell"), ffi.new("VTermPos")
        local all = ""
        for r = 0, self.view.rows - 1 do
            local c = 0
            while c < self.view.cols do
                pos.row, pos.col = r, c
                self.vt_lib.vterm_screen_get_cell(self.screen, pos, cell)
                local cp = cell.chars[0]
                if cp >= 32 and cp < 0x10FFFF and cp ~= 0xFFFFFFFF then
                    all = all .. cp2utf8(cp)
                end
                if tonumber(cell.width) == 2 then c = c + 2 else c = c + 1 end
            end
            all = all .. "\n"
        end
        return all
    end

    at(0.1, function()
        local f = io.open(self.path .. "/autotest.log", "w")
        if f then f:write("LAYOUT SUITE START ", os.date("%H:%M:%S"), "\n") f:close() end
    end)

    -- L1 进终端时 zh IME 已包装(默认布局生效), 记录基准行数/条带高
    local rows_zh, bar_zh
    check("L1 进终端zh→IME已包装", function()
        local cur = rawget(self.view, "addChars")
        assert(type(cur) == "table" and cur._vt_ime_active, "addChars=" .. type(cur))
        rows_zh, bar_zh = self.view.rows, self.view.bar_h
        assert(bar_zh and bar_zh > 0, "zh 布局条带应有高度")
        return "ime_active bar=" .. tostring(bar_zh) .. " rows=" .. tostring(rows_zh)
    end)

    -- L2 🌐 切 en(setKeyboardLayout 与官方按钮同路径)→ 兜底边界必须在场。
    -- 旧 bug: IME revert 把类方法写成实例字段, _installInputBoundary 的
    -- rawget 守卫误判"IME 已包装"跳过, 英文字符只进草稿无人提交。
    at(0.5, function() self.view.keyboard:setKeyboardLayout("en") end)
    check("L2 切en→边界已装(_vt_own)+条带归零", function()
        local cur = rawget(self.view, "addChars")
        assert(type(cur) == "table" and cur._vt_own, "addChars=" .. type(cur))
        assert(not cur._vt_ime_active, "IME 标记残留")
        -- 布局自适应: en 无组词需求, 条带高度归零给网格腾行(PTY winsize 同步)
        assert(self.view.bar_h == 0, "bar_h=" .. tostring(self.view.bar_h))
        assert(self.view.rows >= rows_zh, ("rows %s < 基准 %s"):format(self.view.rows, rows_zh))
        return ("boundary_ok bar=0 rows %s→%s"):format(rows_zh, self.view.rows)
    end)

    -- L3 en 布局直通输入: 字符直达 PTY, shell 回显
    at(0.5, function() self.view:addChars("echo VT11OK") end)
    check("L3 en输入echo VT11OK→屏上回显", function()
        -- 长提示符下命令行会折行, 光标行只剩尾段 → 全屏拼接匹配
        local all = screenAll():gsub("\n", "")
        assert(all:find("echo VT11OK", 1, true), "屏:\n" .. all)
        return "found"
    end)

    -- L4 回车执行 → 输出证明端到端通
    at(0.5, function() self.view:addChars("\n") end)
    check("L4 回车→VT11OK 输出", function()
        local all = screenAll()
        assert(all:find("VT11OK", 1, true), "屏:\n" .. all)
        return "found"
    end)

    -- L5 切回 zh → IME 重新包装, 中文组词仍走草稿(往返对称)
    at(0.5, function() self.view.keyboard:setKeyboardLayout("zh_CN") end)
    check("L5 切回zh→IME重新包装+条带恢复", function()
        local cur = rawget(self.view, "addChars")
        assert(type(cur) == "table" and cur._vt_ime_active, "addChars=" .. type(cur))
        assert(self.view.bar_h == bar_zh, "bar_h=" .. tostring(self.view.bar_h) .. " 期望=" .. tostring(bar_zh))
        assert(self.view.rows == rows_zh, ("rows %s ≠ 基准 %s"):format(self.view.rows, rows_zh))
        return ("ime_back bar=%s rows=%s"):format(self.view.bar_h, self.view.rows)
    end)

    -- L6 再切 en → 边界仍在(第二次往返不劣化)
    at(0.5, function() self.view.keyboard:setKeyboardLayout("en") end)
    check("L6a 二次切en状态诊断", function()
        local cur = rawget(self.view, "addChars")
        return ("type=%s own=%s ime=%s sent=%d chars=%d uwrap=%s"):format(
            type(cur), tostring(type(cur) == "table" and cur._vt_own),
            tostring(type(cur) == "table" and cur._vt_ime_active),
            self.view._vt_sent or -1, #self.view.charlist,
            tostring(self.view.keyboard.uwrap_func ~= nil))
    end)
    at(0.3, function() self.view:addChars("echo VT11AGAIN") end)
    at(0.5, function() self.view:addChars("\n") end)
    at(1.0, function() end)
    check("L6b 二次切en→仍可输入", function()
        local all = screenAll()
        assert(all:find("VT11AGAIN", 1, true), "屏:\n" .. all)
        return "found sent=" .. self.view._vt_sent
    end)

    at(0.5, function() self:_suiteLog("SUITE DONE") end)
end
-- busybox vi 全屏编辑: 中文(删1字)/Eng(删1字符)/中文(删到行首), 过程屏面无残影,
-- :wq 落盘后 od 校验字节层(被删字符不得残留)。
function VTermPlugin:_runVimSuite()
    local t = 3.2
    local function at(dt, fn)
        t = t + dt
        UIManager:scheduleIn(t, function()
            if self.pty and self.pty:isAlive() then fn() end
        end)
    end
    local check_id = 0
    local function check(name, fn)
        check_id = check_id + 1
        local id = check_id
        at(0.05, function()
            local ok, detail = pcall(fn)
            self:_suiteLog(("VCHECK%02d %s: %s | %s"):format(id, name, ok and "PASS" or "FAIL", tostring(detail)))
        end)
    end
    local view = function() return self.view end
    -- 全屏文本(逐行, 宽字符跳续格)
    local function screenAll()
        local cell, pos = ffi.new("VTermScreenCell"), ffi.new("VTermPos")
        local rows = {}
        for r = 0, self.view.rows - 1 do
            local line, c = "", 0
            while c < self.view.cols do
                pos.row, pos.col = r, c
                self.vt_lib.vterm_screen_get_cell(self.screen, pos, cell)
                local cp = cell.chars[0]
                if cp >= 32 and cp < 0x10FFFF and cp ~= 0xFFFFFFFF then
                    line = line .. cp2utf8(cp)
                end
                if tonumber(cell.width) == 2 then c = c + 2 else c = c + 1 end
            end
            rows[#rows + 1] = line
        end
        return table.concat(rows, "\n"), rows
    end
    -- 缓冲首行(vi 的 row0)是否干净: 除空格外无任何可见字符
    local function row0Clean()
        local cell, pos = ffi.new("VTermScreenCell"), ffi.new("VTermPos")
        for c = 0, self.view.cols - 1 do
            pos.row, pos.col = 0, c
            self.vt_lib.vterm_screen_get_cell(self.screen, pos, cell)
            local cp = cell.chars[0]
            if cp ~= 0 and cp ~= 32 and cp ~= 0xFFFFFFFF then
                return false, cp2utf8(cp)
            end
        end
        return true
    end

    at(0.1, function()
        local f = io.open(self.path .. "/autotest.log", "a")
        if f then f:write("VIM SUITE START\n") f:close() end
    end)

    -- 启动 vi (先删旧文件: 上一轮套件留下的内容会占满首行, 使 V6 误判残留)
    at(0.2, function() view():sendBytes("rm -f /tmp/vt5.txt\n") end)
    at(0.5, function() view():addChars("vim /tmp/vt5.txt") end)
    at(0.6, function() view():addChars("\n") end)
    at(1.5, function() view():addChars("i") end) -- 插入模式

    -- V1 输入中文 → 屏上出现
    at(0.6, function() view():addChars("好") end)
    check("V1 vi输入好→屏上出现", function()
        local all = screenAll()
        assert(all:find("好", 1, true), "屏:\n" .. all)
        return "ok"
    end)

    -- V2 删除一个中文字 → 屏上消失且无残影
    at(0.5, function() view():delChar() end)
    check("V2 vi删中文字→全屏无残留", function()
        local all = screenAll()
        assert(not all:find("好", 1, true), "好残留:\n" .. all)
        return "ok"
    end)

    -- V3 输入 Eng
    at(0.4, function() view():addChars("abc") end)
    check("V3 vi输入abc→屏上出现", function()
        local all = screenAll()
        assert(all:find("abc", 1, true), "屏:\n" .. all)
        return "ok"
    end)

    -- V4 删除一个 Eng 字符
    at(0.5, function() view():delChar() end)
    check("V4 vi删c→剩ab", function()
        local all = screenAll()
        assert(all:find("ab", 1, true), "屏:\n" .. all)
        assert(not all:find("abc", 1, true), "c残留:\n" .. all)
        return "ok"
    end)

    -- V5 再输入中文 → ab好
    at(0.4, function() view():addChars("好") end)
    check("V5 vi再输好→ab好", function()
        local all = screenAll()
        assert(all:find("ab好", 1, true), "屏:\n" .. all)
        return "ok"
    end)

    -- V6 删除到行首(好,a,b 共3字) → 全部删净, 首行干净
    at(0.5, function() view():delChar() end)
    at(0.5, function() view():delChar() end)
    at(0.5, function() view():delChar() end)
    check("V6 vi删到行首→首行全净", function()
        local ok, ch = row0Clean()
        assert(ok, "首行残留: " .. tostring(ch))
        return "ok"
    end)

    -- V7 删净后输入 测试 → 落盘 → 字节校验(被删的好不得在文件里)
    at(0.4, function() view():addChars("测试") end)
    check("V7 vi输入测试→屏上出现", function()
        local all = screenAll()
        assert(all:find("测试", 1, true), "屏:\n" .. all)
        return "ok"
    end)
    at(0.5, function() view():addChars("\27") end)   -- Esc
    at(0.5, function() view():addChars(":wq\n") end) -- 落盘退出
    at(1.2, function() view():addChars("od -An -tx1 /tmp/vt5.txt\n") end)
    at(1.8, function() end) -- 等 od 输出渲染
    check("V8 od字节校验=测试UTF8且无好残留", function()
        local all = screenAll()
        assert(all:find("e6 b5 8b", 1, true), "缺支字节:\n" .. all)
        assert(all:find("e8 af 95", 1, true), "缺试字节:\n" .. all)
        assert(not all:find("e5 a5 bd", 1, true), "文件残留好字节:\n" .. all)
        return "bytes ok"
    end)

    at(0.5, function() self:_suiteLog("VIM SUITE DONE") end)
end

-- ==================== VTERM_AUTOTEST=12: vim 内真实 IME 多字词提交 ====================
-- 复现"输入 支持中文 只显示 中文": 在 vim 插入模式用 zh_CN 拼音真实按键
-- (zhichi→空格, zhongwen→空格) 逐词提交, 断言两个词都到达 PTY。
function VTermPlugin:_runImeVimSuite()
    local t = 3.2
    local function at(dt, fn)
        t = t + dt
        UIManager:scheduleIn(t, function()
            if self.pty and self.pty:isAlive() and self.view then fn() end
        end)
    end
    local view = function() return self.view end
    local function screenAll()
        local cell, pos = ffi.new("VTermScreenCell"), ffi.new("VTermPos")
        local all = ""
        for r = 0, self.view.rows - 1 do
            local c = 0
            while c < self.view.cols do
                pos.row, pos.col = r, c
                self.vt_lib.vterm_screen_get_cell(self.screen, pos, cell)
                local cp = cell.chars[0]
                if cp >= 32 and cp < 0x10FFFF and cp ~= 0xFFFFFFFF then
                    all = all .. cp2utf8(cp)
                end
                if tonumber(cell.width) == 2 then c = c + 2 else c = c + 1 end
            end
            all = all .. "\n"
        end
        return all
    end
    local function state(tag)
        local v = self.view
        local tail = table.concat(v.charlist, "", math.min(v._vt_sent + 1, #v.charlist + 1), #v.charlist)
        self:_suiteLog(("%s len=%d sent=%d ls=%s pos=%s tail=%q"):format(tag,
            #v.charlist, v._vt_sent, tostring(v._vt_line_start), tostring(v.charpos), tail))
    end
    local function keys(list, gap)
        for _, k in ipairs(list) do
            at(gap or 0.4, function() view():addChars(k) end)
        end
    end

    at(0.1, function() self:_suiteLog("IME-VIM SUITE START") end)
    -- 本地 shell EN 逐键(用户报障场景: 一次一个字母, 必须逐字显示)
    at(1.0, function() view():addChars("a") end)
    at(0.5, function() view():addChars("b") end)
    at(0.6, function()
        local text = self:_suiteCursorLine()
        self:_suiteLog("IME-VIM 本地shell逐键: " .. ((text:find("ab", 1, true)) and "PASS" or "FAIL"))
    end)
    at(0.4, function() view():delToStartOfLine() end)
    at(0.5, function() view():sendBytes("rm -f /tmp/vt12.txt\n") end)
    at(0.8, function() view():addChars("vim /tmp/vt12.txt") end)
    at(0.8, function() view():addChars("\n") end)
    at(2.0, function() view():addChars("i") end) -- 插入模式(en 布局)
    -- EN 逐键字母: 真实键盘一次一个字母, 必须立刻出现在 vim 里
    at(0.5, function() view():addChars("A") end)
    at(0.5, function() view():addChars("B") end)
    at(0.6, function()
        local all = screenAll()
        self:_suiteLog("IME-VIM EN逐键: " .. ((all:find("AB", 1, true)) and "PASS" or "FAIL"))
    end)
    at(0.4, function() view():delChar() end)
    at(0.4, function() view():delChar() end)
    at(0.8, function() view().keyboard:setKeyboardLayout("zh_CN") end)
    keys({ "z", "h", "i", "c", "h", "i", " " }, 0.5) -- 支持
    at(0.8, function() state("AFTER-WORD1") end)
    keys({ "z", "h", "o", "n", "g", "w", "e", "n", " " }, 0.5) -- 中文
    -- CJK 退格: 1 次 ⌫ 必须删净 1 个汉字(vi 字节级需 3×\x7f, 宽字符 vim 需 1 个)
    at(0.5, function() view():delChar() end)
    at(0.6, function()
        local all = screenAll()
        self:_suiteLog("IME-VIM CJK退格: " .. ((not all:find("文", 1, true)
            or all:find("支持中", 1, true)) and "PASS" or "FAIL"))
    end)
    at(0.8, function()
        state("AFTER-WORD2")
        local all = screenAll()
        self:_suiteLog("SCREEN2:\n" .. all)
        local ok = pcall(function()
            assert(all:find("支持中", 1, true) and not all:find("支持中文", 1, true), "删除后屏幕应为 支持中")
        end)
        self:_suiteLog("IME-VIM 屏上两词: " .. (ok and "PASS" or "FAIL"))
    end)
    -- 落盘 + 十六进制校验: 直接看 vim 缓冲区里到底存了哪些字
    at(0.6, function() view().keyboard:setKeyboardLayout("en") end)
    at(0.5, function() view():addChars("\27") end)      -- Esc
    at(0.5, function() view():addChars(":wq\n") end)    -- 落盘退出
    at(1.5, function() view():addChars("od -An -tx1 /tmp/vt12.txt\n") end)
    at(2.0, function()
        local all = screenAll()
        local ok = pcall(function()
            assert(all:find("e6 94 af e6 8c 81 e4 b8 ad", 1, true),
                "文件字节不是 支持中")
        end)
        self:_suiteLog("IME-VIM 落盘字节: " .. (ok and "PASS" or "FAIL"))
    end)
    at(0.6, function()
        self:_suiteLog("IME-VIM SUITE DONE") -- 收尾自动撤掉 imetest.on(见 _suiteLog)
    end)
end

-- ==================== VTERM_AUTOTEST=13: vim 中文折行行末残留空格复现 ====================
-- 用户报障: vim 中文换行后行末残留空格。三路定位:
--   文件真有空格(od 出现 0x20 字节) = 输入路径 bug;
--   屏幕行尾是真空格(cp==0x20, screenAll 可见) = vi 重绘补空格(显示层);
--   屏幕行只是提前断行(screenAll 无空格) = busybox vi 字节列模型提前换行(固有天花板)。
function VTermPlugin:_runVimWrapSuite()
    local t = 3.2
    local function at(dt, fn)
        t = t + dt
        UIManager:scheduleIn(t, function()
            if self.pty and self.pty:isAlive() and self.view then fn() end
        end)
    end
    local view = function() return self.view end
    local function screenAll()
        local cell, pos = ffi.new("VTermScreenCell"), ffi.new("VTermPos")
        local all = ""
        for r = 0, self.view.rows - 1 do
            local c = 0
            while c < self.view.cols do
                pos.row, pos.col = r, c
                self.vt_lib.vterm_screen_get_cell(self.screen, pos, cell)
                local cp = cell.chars[0]
                if cp >= 32 and cp < 0x10FFFF and cp ~= 0xFFFFFFFF then
                    all = all .. cp2utf8(cp)
                end
                if tonumber(cell.width) == 2 then c = c + 2 else c = c + 1 end
            end
            all = all .. "\n"
        end
        return all
    end
    -- 每行最长的连续空格符 run(cp==0x20 的格子; 空格子 cp==0 不算)
    local function rowTrails()
        local cell, pos = ffi.new("VTermScreenCell"), ffi.new("VTermPos")
        local out = {}
        for r = 0, self.view.rows - 1 do
            local run, maxrun = 0, 0
            local c = 0
            while c < self.view.cols do
                pos.row, pos.col = r, c
                self.vt_lib.vterm_screen_get_cell(self.screen, pos, cell)
                if cell.chars[0] == 0x20 then
                    run = run + 1
                    if run > maxrun then maxrun = run end
                else
                    run = 0
                end
                if tonumber(cell.width) == 2 then c = c + 2 else c = c + 1 end
            end
            out[r] = maxrun
        end
        return out
    end

    at(0.1, function()
        -- 字节流日志(pty.lua 载入时读 flag): 本轮先建, 套件尾删除
        local f = io.open(self.path .. "/echo.dbg.on", "w")
        if f then f:close() end
        self:_suiteLog("WRAP SUITE START")
    end)
    at(0.8, function() view():sendBytes("rm -f /tmp/vt13.txt\n") end)
    at(0.8, function() view():addChars("vim /tmp/vt13.txt") end)
    at(0.8, function() view():addChars("\n") end)
    at(2.0, function() view():addChars("i") end) -- 插入模式(en 布局)
    -- 30 个汉字(90 字节, 显示 60 格) + END: 网格 40 列必折行
    at(0.8, function()
        view():addChars(string.rep("你", 30) .. "END")
    end)
    at(1.5, function()
        local trails, dump = rowTrails(), {}
        for r, n in ipairs(trails) do
            if n > 0 then dump[#dump + 1] = ("r%d=%d"):format(r - 1, n) end
        end
        self:_suiteLog("WRAP TRAIL-SPACES: " .. (dump[1] and table.concat(dump, " ") or "none"))
        -- 行 0..3 逐格 hex dump(cp:宽), 消除 UTF-8 文本歧义
        local cell, pos = ffi.new("VTermScreenCell"), ffi.new("VTermPos")
        for r = 0, 3 do
            local parts = {}
            local c = 0
            while c < self.view.cols and c < 64 do
                pos.row, pos.col = r, c
                self.vt_lib.vterm_screen_get_cell(self.screen, pos, cell)
                parts[#parts + 1] = string.format("%x/%d", tonumber(cell.chars[0]) or 0,
                    tonumber(cell.width) or 0)
                if tonumber(cell.width) == 2 then c = c + 2 else c = c + 1 end
            end
            self:_suiteLog(("WRAP CELLS r%d: %s"):format(r, table.concat(parts, " ")))
        end
        local all = screenAll()
        self:_suiteLog("WRAP SCREEN:\n" .. all)
        local ok = pcall(function()
            assert(all:find("你", 1, true), "屏上应有汉字")
        end)
        self:_suiteLog("WRAP 屏上汉字: " .. (ok and "PASS" or "FAIL"))
        pcall(function()
            require("device").screen:shot(self.path .. "/vt13_vim.png")
        end)
    end)
    at(0.6, function() view():addChars("\27") end)   -- Esc
    at(0.5, function() view():addChars(":wq\n") end) -- 落盘退出
    at(1.5, function() view():addChars("wc -c < /tmp/vt13.txt\n") end)
    at(2.0, function()
        local all = screenAll()
        -- 文件应恰 94 字节(30×3 + END 3 + \n 1), 94 出现在屏上 = 干净
        local ok = pcall(function()
            assert(all:find("94", 1, true), "wc -c 应为 94")
        end)
        self:_suiteLog("WRAP 文件字节数94: " .. (ok and "PASS" or "FAIL"))
        self:_suiteLog("WRAP WC:\n" .. all)
    end)
    at(0.6, function()
        pcall(function()
            os.remove(self.path .. "/echo.dbg.on")
        end)
        self:_suiteLog("WRAP SUITE DONE") -- 收尾自动撤掉 imetest.on(见 _suiteLog)
    end)
end

-- ==================== VTERM_AUTOTEST=8: 快捷栏改版回归 ====================
-- 断言: 按钮条组成(Ctrl-C 已删 / ⌨ / ⇆ / ⇕ 在位), Ctrl 下划线状态,
--       方向手势开关能注册与撤销, Scrollback 开关能把 ↑/↓ 切到本地历史。
function VTermPlugin:_runToolbarSuite()
    local t = 3.4
    local function at(dt, fn)
        t = t + dt
        UIManager:scheduleIn(t, function()
            if self.view then fn() end
        end)
    end
    local n = 0
    local function check(name, fn)
        n = n + 1
        local id = n
        at(0.05, function()
            local ok, detail = pcall(fn)
            self:_suiteLog(("TB%02d %s: %s | %s"):format(id, name, ok and "PASS" or "FAIL", tostring(detail)))
        end)
    end

    at(0.1, function()
        local f = io.open(self.path .. "/autotest.log", "w")
        if f then f:write("TOOLBAR SUITE START\n") f:close() end
    end)

    -- 按钮文字收集(ButtonTable 把结果存在 self.buttons_layout, 每行一个 table)
    local function buttonTexts()
        local texts = {}
        local bt = self.dialog and self.dialog.button_table
        if not bt or not bt.buttons_layout then return texts end
        for _, row in ipairs(bt.buttons_layout) do
            for _, b in ipairs(row) do
                if type(b) == "table" and b.text then texts[#texts + 1] = tostring(b.text) end
            end
        end
        return texts
    end

    check("TB1 Ctrl-C 已删除", function()
        for _, tx in ipairs(buttonTexts()) do
            assert(not tx:find("Ctrl-C", 1, true), "仍有 Ctrl-C: " .. tx)
        end
        return "ok"
    end)

    check("TB2 新按钮在位(⌨/⇆/⇕)", function()
        local want = { ["⌨"] = false, ["⇆"] = false, ["⇕"] = false }
        for _, tx in ipairs(buttonTexts()) do
            for k in pairs(want) do if tx:find(k, 1, true) then want[k] = true end end
        end
        for k, v in pairs(want) do assert(v, "缺按钮 " .. k) end
        return "ok"
    end)

    check("TB3 Ctrl 激活→按钮显示 Ctrl*, 用掉自动复位", function()
        local v = self.view
        assert(v._vt_ctrl_btn, "按钮引用未抓到(findBtn 失败)")
        v._vt_ctrl_pending = true
        v._vt_ctrl_btn:setText("Ctrl*", v._vt_ctrl_btn.width)
        v:_ctrlWrite("c") -- Ctrl 生效: 发 \x03 并触发复位回调
        assert(not v._vt_ctrl_pending, "Ctrl 应被消费")
        assert(v._vt_ctrl_btn.text == "Ctrl", "按钮应复位, 实得 " .. tostring(v._vt_ctrl_btn.text))
        return "ok"
    end)

    check("TB4 方向手势开关: 开→注册, 关→撤销", function()
        local v = self.view
        -- 默认态(全新会话从未切过 ⇆)也必须已注册上下滑处理器:
        -- 启动路径现在走 setArrowGestures(false)(⇕ 翻页依赖它)
        assert(v.ges_events and v.ges_events.VTermSwipe and v.ges_events.VTermPan,
            "默认态手势未注册")
        v:setArrowGestures(true)
        assert(v._vt_arrows and v.ges_events and v.ges_events.VTermSwipe, "手势未注册")
        v:setArrowGestures(false)
        assert(not v._vt_arrows, "开关未复位")
        -- ⇆ 关: 一次拖动一发 —— swipe(快甩) + pan(墨水屏慢速拖动)都要在位,
        -- 连发状态机(hold_pan)不需要
        assert(v.ges_events.VTermSwipe, "⇆关时 swipe 应保留(上下滑动)")
        assert(v.ges_events.VTermPan and v.ges_events.VTermPanRelease
            and v.ges_events.VTermTouch, "⇆关时 pan/touch 应注册")
        assert(not v.ges_events.VTermHoldPan, "⇆关时连发状态机应撤销")
        return "ok (swipe+pan 一次一发)"
    end)

    check("TB5 方向手势映射: 左/右/上/下 → 方向键", function()
        local v = self.view
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        v:setArrowGestures(true)
        for _, d in ipairs({ "left", "right", "up", "down" }) do
            v:onVTermSwipe(nil, { direction = d })
        end
        v._vt_write = orig
        assert(sent[1] == "\27[D" and sent[2] == "\27[C" and sent[3] == "\27[A" and sent[4] == "\27[B",
            table.concat(sent, "|"))
        return table.concat(sent, "|")
    end)

    check("TB6 Scrollback 关: ↑/↓ 走远端翻页", function()
        local v = self.view
        v._vt_sb_mode = false
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        v:scrollUp(false)
        v:scrollDown(false)
        v._vt_write = orig
        assert(sent[1] == "\27[5~" and sent[2] == "\27[6~", table.concat(sent, "|"))
        return table.concat(sent, "|")
    end)

    -- 先让 shell 吐够屏数, TB7 才有历史可翻
    at(0.1, function() self.view:sendBytes("seq 1 40\n") end)
    at(2.0, function() end)

    check("TB7 Scrollback 开 + 有历史: ↑ 翻本地历史", function()
        local v = self.view
        v._vt_sb_mode = true
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        local depth = v._vt_sb and v._vt_sb:depth() or 0
        local moved = v._vt_sb and v._vt_sb:scrollUp(1) or 0
        v:scrollDown(false) -- 回到底
        v._vt_write = orig
        assert(depth > 0, "没有历史行可翻(depth=0)")
        assert(moved == 1, "scrollUp 未取到历史行")
        assert(#sent == 0, "本地翻看不应给 PTY 发字节: " .. table.concat(sent, "|"))
        return "depth=" .. depth
    end)

    check("TB8 手势真实派发: 对话框层收 Gesture Event → 方向键", function()
        local v = self.view
        local Geom = require("ui/geometry")
        local Event = require("ui/event")
        v:setArrowGestures(true)
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        -- 真实链路: Input 把裸 ges 表包成 Event:new("Gesture", ges) 再进
        -- handleEvent → WidgetContainer 逐层转发 → InputContainer:onGesture
        -- → ges_events 匹配 → onVTermSwipe
        self.dialog:handleEvent(Event:new("Gesture", {
            ges = "swipe",
            direction = "left",
            pos = Geom:new{ x = v.dimen.x + 40, y = v.dimen.y + 40 },
        }))
        v._vt_write = orig
        v:setArrowGestures(false)
        assert(sent[1] == "\27[D", "swipe left 未到达 view, sent=" .. table.concat(sent, "|"))
        return "reached"
    end)

    check("TB9 ⌨ 收放: 点击重建对话框(键盘+按钮栏同步, view 换新)", function()
        local v0 = self.view
        local bt = self.dialog and self.dialog.button_table
        assert(bt and bt.buttons_layout, "ButtonTable 不存在")
        local kb_btn
        for _, row in ipairs(bt.buttons_layout) do
            for _, b in ipairs(row) do
                if type(b) == "table" and b.text == "⌨" then kb_btn = b end
            end
        end
        assert(kb_btn and kb_btn.callback, "⌨ 按钮或回调未找到")
        local t0 = v0:isKeyboardVisible()
        kb_btn:callback() -- 与真机点击同路径: ButtonTable 分发 → _toggleKeyboardBar
        local v1 = self.view
        assert(v1 ~= v0, "对话框应已重建(view 换新)")
        local t1 = v1:isKeyboardVisible()
        assert(t1 == (not t0), "键盘可见性未翻转: " .. tostring(t0) .. "→" .. tostring(t1))
        assert(v1._vt_collapsed == (not t1), "collapsed=" .. tostring(v1._vt_collapsed)
            .. " dlg_kb=" .. tostring(self.dialog.keyboard_visible)
            .. " t0=" .. tostring(t0) .. " t1=" .. tostring(t1))
        assert(v1.vt and v1._vt_sb and v1._vt_write, "重建后终端状态未重挂")
        kb_btn:callback() -- 旧按钮的闭包仍指 plugin, 复原同样有效
        local v2 = self.view
        assert(v2:isKeyboardVisible() == t0, "复原失败")
        return tostring(t0) .. "→" .. tostring(t1) .. "→" .. tostring(t0)
            .. " rows " .. v0.rows .. "→" .. v1.rows .. "→" .. v2.rows
            .. " h " .. tostring(v0.height) .. "→" .. tostring(v1.height) .. "→" .. tostring(v2.height)
    end)

    check("TB10 松手事件名: hold_release(单指标准名, 错名松手不停)", function()
        local v = self.view
        v:setArrowGestures(true)
        local ok
        for _, gr in ipairs(v.ges_events.VTermHoldPanRelease or {}) do
            if gr.ges == "hold_release" then ok = true end
        end
        v:setArrowGestures(false)
        assert(ok, "VTermHoldPanRelease 未注册 hold_release 事件")
        return "hold_release"
    end)

    check("TB11 翻看态发方向键: 自动滚回实时帧再发(否则 shell 响应被历史帧遮住)", function()
        local v = self.view
        v:setArrowGestures(true)
        v._vt_sb_mode = true
        assert(v._vt_sb and v._vt_sb:scrollUp(1) == 1, "无历史可翻")
        assert(v._vt_sb:isScrolling(), "应处于翻看态")
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        v:onVTermSwipe(nil, { direction = "left" })
        v._vt_write = orig
        v:setArrowGestures(false)
        assert(not v._vt_sb:isScrolling(), "发方向键后应已滚回实时帧")
        assert(sent[1] == "\27[D", "方向键应发出: " .. (sent[1] or "none"))
        v:scrollDown(false)
        return "live+sent"
    end)

    check("TB11b ⇕ 开启: 上下滑=本地翻页(等效 PageUp/PageDown), 不动 PTY", function()
        local v = self.view
        v:setArrowGestures(true)
        v._vt_sb_mode = true
        local depth = v._vt_sb:depth()
        assert(depth > 0, "无历史可翻")
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        v:onVTermSwipe(nil, { direction = "north" }) -- 上滑=PageUp
        assert(v._vt_sb:isScrolling(), "上滑后应处于翻看态")
        v:onVTermSwipe(nil, { direction = "south" }) -- 下滑=PageDown
        v._vt_write = orig
        v:setArrowGestures(false)
        v:scrollDown(false) -- 回实时帧
        assert(#sent == 0, "翻页不应给 PTY 发字节: " .. table.concat(sent, "|"))
        return "paged depth=" .. depth
    end)

    check("TB12 慢速拖动 pan: 注册且走节流方向键(墨水屏滑动普遍判成 pan 而非 swipe)", function()
        local v = self.view
        v:setArrowGestures(true)
        assert(v.ges_events.VTermPan and v.ges_events.VTermPanRelease, "pan 手势未注册")
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        v:onVTermPan(nil, { direction = "right" }) -- 首下立即发
        v:onVTermPan(nil, { direction = "right" }) -- 同方向节流(不发)
        v:onVTermPan(nil, { direction = "left" })  -- 换向立即发
        v:onVTermPanRelease(nil, {})
        v._vt_write = orig
        v:setArrowGestures(false)
        assert(sent[1] == "\27[C" and sent[2] == "\27[D",
            "pan 方向键序列错: " .. table.concat(sent, "|"))
        assert(#sent == 2, "同方向节流失效或松手后仍重复: " .. #sent)
        return table.concat(sent, "|")
    end)

    check("TB13 手势范围: 起点在网格即命中(终点滑出网格顶部/入键盘也不丢)", function()
        local Geom = require("ui/geometry")
        local v = self.view
        v:setArrowGestures(true)
        local gr = v.ges_events.VTermPan[1]
        local g = v.ges_events and v:_gridRegion()
        local in_grid = Geom:new{ x = g.x + 10, y = g.y + 10 }
        local up_out = Geom:new{ x = g.x + 10, y = math.max(1, g.y - 20) } -- 网格上方(标题区)
        local down_out = Geom:new{ x = g.x + 10, y = g.y + g.h + 60 }     -- 网格下方(键盘区)
        local ok1 = gr:match{ ges = "pan", pos = in_grid, start_pos = in_grid }
        local ok2 = gr:match{ ges = "pan", pos = up_out, start_pos = in_grid }
        local ok3 = gr:match{ ges = "pan", pos = down_out, start_pos = in_grid }
        local ok4 = gr:match{ ges = "pan", pos = up_out, start_pos = up_out }
        local ok5 = gr:match{ ges = "tap", pos = in_grid, start_pos = in_grid } -- 事件名不同
        v:setArrowGestures(false)
        assert(ok1, "网格内应命中")
        assert(ok2 and ok3, "起点在网格、终点出界应命中(上/下)")
        assert(not ok4, "全在网格外不应命中")
        assert(not ok5, "事件名不同不应命中(否则 tap 等触摸被手势吃掉)")
        return "start_pos"
    end)

    check("TB14 罗盘方向词映射: south/north/east/west(+对角主轴) → 方向键(真机 ges.log 实证)", function()
        local v = self.view
        local cases = {
            { "south", "\27[B" }, { "north", "\27[A" }, { "east", "\27[C" }, { "west", "\27[D" },
            { "south_east", "\27[B" }, { "northwest", "\27[A" }, -- 对角垂直轴优先
            { "down", "\27[B" }, { "left", "\27[D" }, -- 兼容注入测试词
        }
        for _, c in ipairs(cases) do
            assert(v:_arrowSeq(c[1]) == c[2], c[1] .. " → " .. tostring(v:_arrowSeq(c[1])))
        end
        return "compass"
    end)

    check("TB15 连发模型: 同向只发一次; 停顿后连发可启动; 抬起立即硬取消", function()
        local v = self.view
        v._vt_sb_mode = false -- 本测试验证纯方向词映射, 关掉 ⇕ 翻页路由
        v._vt_sb_mode = false -- 本测试验证纯方向词映射, 关掉 ⇕ 翻页路由
        v:setArrowGestures(true)
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        v:onVTermPan(nil, { direction = "south" }) -- 首键
        v:onVTermPan(nil, { direction = "south" }) -- 同向不发
        v:onVTermPan(nil, { direction = "south" }) -- 同向不发
        v:onVTermPan(nil, { direction = "east" })  -- 换向再发一次
        v:onVTermPan(nil, { direction = "east" })  -- 同向不发
        assert(#sent == 2 and sent[1] == "\27[B" and sent[2] == "\27[C",
            "滑动模型序列: " .. table.concat(sent, "|"))
        v:_ensureLive()
        v:_scheduleArrowRepeat() -- 模拟停顿 1s 到期后的连发启动
        assert(v._vt_arrow_fn ~= nil, "连发应已启动")
        v:_stopArrowRepeat()     -- 手指抬起: 硬取消
        assert(v._vt_arrow_fn == nil and not v._vt_arrow_dir, "抬起应立即停")
        v._vt_write = orig
        v:setArrowGestures(false)
        return "single+hold+stop"
    end)

    check("TB16 停顿判定: 触摸抖动(<阈值)不打断 1s 停顿计时(真机按住不动 pos 仍微动 1~4px)", function()
        local Geom = require("ui/geometry")
        local v = self.view
        v._vt_sb_mode = false -- 本测试验证纯方向词映射, 关掉 ⇕ 翻页路由
        v:setArrowGestures(true)
        v:onVTermPan(nil, { direction = "south", pos = Geom:new{ x = 100, y = 100 } }) -- 建基准
        local seq0 = v._vt_hold_seq
        v:onVTermPan(nil, { direction = "south", pos = Geom:new{ x = 105, y = 103 } }) -- 抖动 ~6px
        assert(v._vt_hold_seq == seq0, "抖动不应重置停顿计时")
        v:onVTermPan(nil, { direction = "south", pos = Geom:new{ x = 140, y = 160 } }) -- 真移动
        assert(v._vt_hold_seq == seq0 + 1, "真移动应重置停顿计时")
        v:setArrowGestures(false)
        return "jitter-ok"
    end)

    check("TB17 滑出网格终止: 手指拖出网格区即停状态机(键盘上按删除不误连发)", function()
        local Geom = require("ui/geometry")
        local v = self.view
        v._vt_sb_mode = false -- 本测试验证纯方向词映射, 关掉 ⇕ 翻页路由
        v:setArrowGestures(true)
        local g = v:_gridRegion()
        v:onVTermPan(nil, { direction = "south", pos = Geom:new{ x = g.x + 50, y = g.y + 50 } })
        assert(v._vt_arrow_dir, "网格内滑动应设方向")
        v:onVTermPan(nil, { direction = "south", pos = Geom:new{ x = g.x + 50, y = g.y + g.h + 100 } })
        assert(v._vt_arrow_dir == nil, "拖出网格应终止状态机")
        v:_scheduleArrowRepeat() -- 模拟停顿计时到期: dir 已清, 连发不得启动
        assert(v._vt_arrow_fn == nil, "出网格后连发不应启动")
        v:setArrowGestures(false)
        return "out-stop"
    end)

    check("TB18 抬起作废停顿计时: pan 后 swipe 不双发、方向清空、连发不启动", function()
        local Geom = require("ui/geometry")
        local v = self.view
        v._vt_sb_mode = false -- 本测试验证纯方向词映射, 关掉 ⇕ 翻页路由
        v:setArrowGestures(true)
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        v:onVTermPan(nil, { direction = "north", pos = Geom:new{ x = 100, y = 100 } })
        v:onVTermSwipe(nil, { direction = "north" }) -- 抬起判定为 swipe
        v._vt_write = orig
        assert(#sent == 1, "pan+swipe 应只发一次(不双发): " .. #sent)
        assert(v._vt_arrow_dir == nil, "swipe 后方向状态应清空(停顿计时作废)")
        v:_scheduleArrowRepeat()
        assert(v._vt_arrow_fn == nil, "方向已清, 连发不得启动")
        -- 纯 swipe 手势(pan 流没发过): 仍应发一次
        local sent2 = {}
        v._vt_write = function(s) sent2[#sent2 + 1] = s end
        v:setArrowGestures(true)
        v:onVTermSwipe(nil, { direction = "west" })
        v._vt_write = orig
        v:setArrowGestures(false)
        assert(sent2[1] == "\27[D", "纯 swipe 应发一次: " .. tostring(sent2[1]))
        return "swipe-cleanup"
    end)

    check("TB19 touch 作废会话: 滑动后去键盘打字(触摸按下)立即作废停顿计时", function()
        local Geom = require("ui/geometry")
        local v = self.view
        v._vt_sb_mode = false -- 本测试验证纯方向词映射, 关掉 ⇕ 翻页路由
        v:setArrowGestures(true)
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        v:onVTermPan(nil, { direction = "north", pos = Geom:new{ x = 100, y = 100 } })
        assert(v._vt_arrow_dir == "north", "滑动应设方向")
        v:onVTermTouch(nil, {}) -- 手指落到键盘上打字(触摸按下)
        assert(v._vt_arrow_dir == nil and v._vt_arrow_fn == nil, "touch 应作废滑动会话")
        assert(v._vt_last_pan_pos == nil, "touch 应清位置基准")
        -- 停顿计时代号已失效: 即使 1s 到期回调跑, dir=nil → 连发不启动
        v:_scheduleArrowRepeat()
        assert(v._vt_arrow_fn == nil, "作废后连发不得启动")
        v._vt_write = orig
        v:setArrowGestures(false)
        return "touch-reset"
    end)

    check("TB20 会话编辑: update 覆盖原会话 / 另存为新增一份", function()
        local tmp = self.path .. "/test_sessions_tmp.json"
        local wf = io.open(tmp, "w")
        if wf then wf:write("[]") wf:close() end -- 空文件起步, 避开 load 的默认会话 fallback
        local sm = SessionMgr.new(tmp)
        sm:add({ type = "ssh", name = "A", host = "1.1.1.1", port = 22, user = "root" })
        sm:update(1, { type = "ssh", name = "A2", host = "2.2.2.2", port = 2222, user = "root" })
        local l = sm:list()
        assert(#l == 1 and l[1].name == "A2" and l[1].host == "2.2.2.2" and l[1].port == 2222,
            "update 应覆盖原会话")
        sm:add({ type = "ssh", name = "B", host = "3.3.3.3", port = 22, user = "root" }) -- 另存为
        assert(#sm:list() == 2 and sm:list()[2].name == "B", "另存为应新增一份")
        -- 覆盖后落盘验证
        local sm2 = SessionMgr.new(tmp)
        assert(#sm2:list() == 2 and sm2:list()[1].name == "A2", "修改应已落盘")
        os.remove(tmp)
        return "update+save-as"
    end)

    check("TB21 回车发 CR: addChars(\\n) 实发 \\r(raw 模式 TUI 如 pi agent 只认 CR 为发送)", function()
        local v = self.view
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        v:addChars("\n")
        v._vt_write = orig
        assert(sent[1] == "\r", "回车应发 CR(0x0D), 实得: " ..
            (sent[1] and string.format("0x%02X", string.byte(sent[1])) or "nil"))
        return "CR"
    end)

    check("TB22 字号热切换: 对话框重建+格子重算, PTY/scrollback 会话保持", function()
        local v0 = self.view
        local old_rows, old_cols = v0.rows, v0.cols
        local old_sb = self._vt_sb
        local old_vt, old_pty = self.vt, self.pty
        -- 设置跨运行持久化(上次跑套件可能留了值), 目标字号选一个与当前不同的
        local cur_fs = G_reader_settings:readSetting("vterm_font_size") or 18
        local new_fs = (cur_fs == 24) and 18 or 24
        self:_changeFontSize(new_fs)
        local v1 = self.view
        assert(v1 and v1 ~= v0, "view 应为重建后的新实例")
        assert(self.vt == old_vt and self.pty == old_pty, "PTY/vt 应原样保留")
        assert(self._vt_sb == old_sb, "scrollback 应原样保留")
        assert(v1.font_size == new_fs, "新 view 字号=" .. tostring(v1.font_size))
        assert(v1.rows ~= old_rows or v1.cols ~= old_cols,
            ("网格应重算: rows %d→%d cols %d→%d cell %s→%sx%s w %s→%s fs %s→%s"):format(
            old_rows, v1.rows, old_cols, v1.cols,
            tostring(v0.cell_w), tostring(v1.cell_w), tostring(v1.cell_h),
            tostring(v0.width), tostring(v1.width),
            tostring(v0.font_size), tostring(v1.font_size)))
        assert(v1.vt == old_vt and v1._vt_write and v1._vt_sb, "终端状态未挂回新 view")
        assert(self.pty:isAlive(), "PTY 应存活")
        -- 还原默认字号 18(不守恒进入时的任意值: 历史污染值会让后续 mode4
        -- 的折行敏感断言错位), 重建一次同时验证切换可往返
        self:_changeFontSize(18)
        return ("rows %d→%d cols %d→%d pty-alive"):format(old_rows, self.view.rows, old_cols, self.view.cols)
    end)

    -- TB23 ⇆关闭时上下滑 = PuTTY 式阶梯: ⇕关=↑/↓(逐行), ⇕开=远端 PageUp/PageDown
    -- (⇆开+⇕开=本地历史翻页见 TB11b; ⇆开+⇕关=带连发方向手势见 TB5/TB12)
    check("TB23 ⇆关上下滑→方向键(⇕关)/ 翻页键(⇕开)", function()
        local v = self.view
        v:setArrowGestures(false) -- ⇆ 关: swipe/pan 注册, 按 ⇕ 分派
        assert(v.ges_events.VTermSwipe ~= nil, "⇆关时 swipe 注册应保留")
        assert(v.ges_events.VTermPan ~= nil, "⇆关时 pan 应注册(墨水屏慢速拖动)")
        assert(v.ges_events.VTermHoldPan == nil, "⇆关时连发状态机应摘除")
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        -- ⇕ 关: 上滑=↑ 下滑=↓
        v._vt_sb_mode = false
        local up = v:_pageAction("north")
        local down = v:_pageAction("south")
        assert(up and down, "⇕关时上下滑应有方向键动作")
        up(); down()
        assert(sent[#sent - 1] == "\27[A" and sent[#sent] == "\27[B",
            "应发 ↑/↓: " .. tostring(sent[#sent - 1]) .. "/" .. tostring(sent[#sent]))
        -- ⇕ 开: 上滑=PageUp 下滑=PageDown(远端)
        v._vt_sb_mode = true
        local p_up = v:_pageAction("north")
        local p_down = v:_pageAction("south")
        assert(p_up and p_down, "⇕开时上下滑应有翻页动作")
        p_up(); p_down()
        assert(sent[#sent - 1] == "\27[5~" and sent[#sent] == "\27[6~",
            "应发 PageUp/PageDown: " .. tostring(sent[#sent - 1]) .. "/" .. tostring(sent[#sent]))
        -- 水平方向无动作(不吞左右手势语义)
        assert(v:_pageAction("east") == nil, "水平滑动不应触发上下滚动")
        -- 慢速拖动(pan): 墨水屏的实际手势路径 —— 一次拖动只发一发;
        -- 同手势收尾的 swipe 不得补发; 抬手后新手势才再发。
        sent = {}
        v:onVTermPan(nil, { direction = "north" })
        v:onVTermPan(nil, { direction = "north" })   -- 同手势第二帧: 不重发
        v:onVTermSwipe(nil, { direction = "north" }) -- 收尾 swipe: 去重
        v:onVTermPanRelease(nil, {})                 -- 抬手: 会话结束
        v:onVTermPan(nil, { direction = "south" })   -- 新手势: PageDown
        assert(#sent == 2 and sent[1] == "\27[5~" and sent[2] == "\27[6~",
            "pan 一次一发/去重失败: " .. table.concat(sent, "|"))
        -- 还原 ⇆ 开启(套件其它用例的假设)
        v._vt_sb_mode = false
        v._vt_write = orig
        v:setArrowGestures(true)
        return "↑/↓ + 5~/6~ + pan-once + east-nil"
    end)

    -- TB24 长按终端区: 不弹 InputText 的剪贴板面板(复制/粘贴/全选), 且抬指一并消费
    check("TB24 长按不弹剪贴板面板", function()
        local v = self.view
        local shown = 0
        local orig_show = UIManager.show
        UIManager.show = function() shown = shown + 1 end
        local ok, err = pcall(function() v:onHoldTextBox(nil, {}) end)
        UIManager.show = orig_show
        assert(ok, tostring(err))
        assert(shown == 0, "长按仍弹出面板: shown=" .. shown)
        assert(v._hold_handled == true, "hold 未标记消费")
        assert(v:onHoldReleaseTextBox(nil, {}) == true, "hold_release 未被消费")
        return "no-popup"
    end)

    -- TB25 Ctrl 变换域: 全控制字符(Ctrl+]=0x1D vim 跳 tag / Space→NUL / ?→DEL)
    -- + ESC 序列不变换 + 无挂起透传
    check("TB25 Ctrl 变换: a→0x01 ]→0x1D v→0x16 Space→NUL ESC序列透传 无挂起透传", function()
        local v = self.view
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        v._vt_ctrl_pending = true
        v:_ctrlWrite("a")
        v._vt_ctrl_pending = true
        v:_ctrlWrite("]")
        v._vt_ctrl_pending = true
        v:_ctrlWrite("v")
        v._vt_ctrl_pending = true
        v:_ctrlWrite("\27[A") -- ESC 序列: 不变换
        v._vt_ctrl_pending = true
        v:_ctrlWrite(" ")
        v._vt_ctrl_pending = false
        v:_ctrlWrite("x")     -- 无挂起: 透传
        v._vt_write = orig
        assert(sent[1] == "\1" and sent[2] == "\29" and sent[3] == "\22",
            string.format("%q|%q|%q", sent[1], sent[2], sent[3]))
        assert(sent[4] == "\27[A", "ESC 序列不应被 Ctrl 变换")
        assert(sent[5] == "\0", "Ctrl+Space 应为 NUL")
        assert(sent[6] == "x", "无挂起应透传")
        return "01/1D/16/esc/00/pass"
    end)

    -- TB26 软键盘 Shift + 翻页手势: Shift 挂起 → \27[5;2~/\27[6;2~, 否则裸序列
    check("TB26 Shift+翻页手势: Shift 挂起→5;2~/6;2~, 关→裸 5~/6~", function()
        local v = self.view
        local sent = {}
        local orig = v._vt_write
        v._vt_write = function(s) sent[#sent + 1] = s end
        local kbd = v.keyboard
        v._vt_arrows = false
        v._vt_sb_mode = true
        v.keyboard = { shiftmode = true }
        v:_pageAction("north")()
        v:_pageAction("south")()
        v.keyboard.shiftmode = false
        v:_pageAction("north")()
        v.keyboard = kbd
        v._vt_write = orig
        assert(sent[1] == "\27[5;2~" and sent[2] == "\27[6;2~" and sent[3] == "\27[5~",
            table.concat(sent, "|"))
        return "5;2/6;2/plain"
    end)

    -- TB27 Ctrl+] 经真实键盘入口(长按弹窗同款 keyboard:addChar)诊断:
    -- en 直通与 zh IME 挂载两布局, 记录 charlist/sent/pending/包装层状态
    check("TB27 Ctrl* + keyboard:addChar(']') en/zh 两布局 → 0x1D", function()
        local v = self.view
        local orig_layout = G_reader_settings:readSetting("keyboard_layout") or "en"
        local orig = v._vt_write
        local sent = {}
        v._vt_write = function(s) sent[#sent + 1] = s end
        local function st(tag)
            self:_suiteLog(("TB27 %s: cl=%d sent=%d pend=%s ime=%s inst=%s"):format(tag,
                #v.charlist, v._vt_sent or -1, tostring(v._vt_ctrl_pending),
                tostring(v._vt_ime_active), tostring(rawget(v, "addChars") ~= nil)))
        end
        for _, layout in ipairs({ "en", "zh_CN" }) do
            v.keyboard:setKeyboardLayout(layout)
            st(layout .. "-before")
            local n0 = #v.charlist
            v._vt_ctrl_pending = true
            v.keyboard:addChar("]") -- 长按弹窗选 ] 的同款入口(VirtualKey→addChar)
            st(layout .. "-after")
            sent[#sent + 1] = layout
            sent[#sent + 1] = (#v.charlist > n0) and table.concat(
                { v.charlist[n0 + 1] and string.format("%02x", v.charlist[n0 + 1]:byte() or 0) or "?" }) or "nochar"
            sent[#sent + 1] = "END"
        end
        v._vt_write = orig
        v.keyboard:setKeyboardLayout(orig_layout)
        local dump = {}
        for i, s in ipairs(sent) do
            dump[#dump + 1] = i .. ":" .. string.format("%q", s)
        end
        self:_suiteLog("TB27 sent-dump: " .. table.concat(dump, " "))
        local ok_en = sent[1] == "\29"
        local ok_zh = sent[5] == "\29"
        assert(ok_en and ok_zh,
            ("en=%s zh=%s dump=%s"):format(tostring(sent[1]), tostring(sent[5]),
            table.concat(dump, " ")))
        return "en+zh both 0x1D"
    end)

    -- TB29 设置对话框"标题栏电量与时间"勾选行: 结构断言 + 待定态/应用保存语义
    -- + 油漆后截图留证(0.8s 后), 收尾时间轴相应后移
    check("TB29 设置对话框勾选行: 待定态+点应用才保存", function()
        local orig_on = self:_titleInfoEnabled()
        self:showSettings()
        local dlg
        for _, e in ipairs(UIManager._window_stack or {}) do
            local w = e.widget
            if w and w.widget_frame and w.left_widget and w.right_widget then dlg = w end
        end
        assert(dlg, "设置对话框未打开")
        local vg = dlg.widget_frame[1]
        local cb = vg[3] and vg[3][1]
        assert(cb and cb.toggleCheck and type(cb.text) == "string"
                and (cb.text:find("电量") or cb.text:find("attery")), -- 中英双语 UI
            "勾选行未插在按钮排前: " .. tostring(cb and cb.text))
        assert(vg[4] and vg[4][1] and not vg[4][1].toggleCheck, "按钮排错位")
        -- 无变更时应用键不使能; 勾选产生待定态后点亮
        local bt = vg[4][1]
        local lastrow = bt.buttons_layout[#bt.buttons_layout]
        local okbtn = lastrow[#lastrow]
        assert(okbtn.enabled == false, "无变更时应用键应禁用, 实得 " .. tostring(okbtn.enabled))
        -- 切到关: 只记待定态, 不持久化不生效
        cb:toggleCheck(); cb.callback()
        assert(dlg._vt_title_pending == false, "待定态未记录")
        assert(okbtn.enabled == true, "有待定态时应用键应点亮")
        assert(G_reader_settings:readSetting("vterm_title_info") ~= false, "未应用就持久化了")
        -- 点应用: 持久化 false + 标题条摘除
        dlg.callback(18, 2000)
        assert(G_reader_settings:readSetting("vterm_title_info") == false, "应用未持久化")
        assert(self._title_info == nil, "应用后未摘除信息组件")
        -- 再切回开 + 应用: 重挂
        cb:toggleCheck(); cb.callback()
        dlg.callback(18, 2000)
        assert(G_reader_settings:readSetting("vterm_title_info") ~= false, "应用未恢复开启")
        assert(self._title_info ~= nil, "应用后未重挂信息组件")
        -- 油漆完成后再截图留证并关对话框
        UIManager:scheduleIn(0.8, function()
            pcall(function()
                require("device").screen:shot(self.path .. "/vt_settings_shot.png")
            end)
            pcall(function() dlg:onClose() end)
            if not orig_on then -- 用户原本关着: 还原回关
                G_reader_settings:saveSetting("vterm_title_info", false)
                self:_stopTitleInfo()
            end
        end)
        return "row@vg3 checked=" .. tostring(cb.checked) .. " apply-save-ok"
    end)

    -- TB31 点击标题栏 = 全屏刷新: 点击层挂在 OverlapGroup 底层且回调可用
    check("TB31 标题栏点击刷新层挂载+回调", function()
        local tb = self.dialog and self.dialog.title_bar
        assert(tb and rawget(tb, "_vt_tap"), "标题栏点击层未挂载")
        assert(tb[1] == tb._vt_tap, "点击层应在最底层(首位)")
        assert(type(tb._vt_tap.onTapTitleRefresh) == "function", "刷新回调缺失")
        assert(tb._vt_tap:onTapTitleRefresh() == true, "回调应返回 true(消费手势)")
        return "tap-layer ok"
    end)

    at(1.2, function()
        self:_suiteLog("TOOLBAR SUITE DONE")
        -- 视觉留证: 用 KOReader 自带截图器把当前终端界面存到插件目录
        local ok = pcall(function()
            local Screenshoter = require("ui/widget/screenshoter")
            local shot = Screenshoter:new{ ui = self.ui }
            shot:onScreenshot("vterm_toolbar")
        end)
        self:_suiteLog("SHOT " .. (ok and "OK" or "FAIL"))
        -- 套件跑完自动退出, 便于无人值守(模拟器/真机)
        UIManager:scheduleIn(8, function() self:closeTerminal() end)
    end)

    -- TB30 探针(DONE 截图后、closeTerminal 前): 用户实测字号12收键盘顶部越界
    -- → 切 12 号 → 截图(展开态) → 收键盘 → 状态日志+截图 → 还原
    local function vt30state(tag)
        local v = self.view
        local d = v and v.dimen
        self:_suiteLog(("TB30 %s: rows=%s cell=%s dimen=%s,%s,%s,%s h=%s extra=%s vgoff=%s"):format(
            tag, tostring(v and v.rows), tostring(v and v.cell_h),
            d and d.x or -1, d and d.y or -1, d and d.w or -1, d and d.h or -1,
            tostring(v and v.height), tostring(v and v._vt_extra_h),
            tostring(self.dialog and self.dialog.vgroup and self.dialog.vgroup._offsets
                and self.dialog.vgroup._offsets[3] or "?")))
    end
    UIManager:scheduleIn(8.0, function()
        if not self.view or not self.dialog then return end
        pcall(function()
            self:_suiteLog("TB30 font12 rebuild start")
            self:_changeFontSize(12)
        end)
        UIManager:scheduleIn(1.2, function()
            vt30state("show-font12")
            pcall(function()
                require("device").screen:shot(self.path .. "/vt_kbshow_shot.png")
            end)
        end)
        UIManager:scheduleIn(1.4, function()
            pcall(function()
                self:_suiteLog("TB30 kbhide visible=" .. tostring(self.dialog:isKeyboardVisible()))
                self:_toggleKeyboardBar()
            end)
        end)
        UIManager:scheduleIn(2.6, function()
            vt30state("hide-font12")
            pcall(function()
                require("device").screen:shot(self.path .. "/vt_kbhide_shot.png")
            end)
            self:_suiteLog("TB30 kbhide shot done")
        end)
        UIManager:scheduleIn(2.8, function()
            pcall(function() self:_toggleKeyboardBar() end) -- 还原展开态
        end)
        UIManager:scheduleIn(3.0, function()
            pcall(function() self:_changeFontSize(18) end) -- 还原字号
        end)
    end)
end

function VTermPlugin:closeTerminal()
    os.remove(self.path .. "/terminal.pid")
    -- 标题栏时间/电量刷新链失效(下次 startTerminal 重新起链)
    self._title_seq = (self._title_seq or 0) + 1
    self._title_info = nil
    self._title_tick_pending = false
    if self.pty then
        self.pty:close()
        self.pty = nil
    end
    if self.vt then
        self.vt_lib.vterm_free(self.vt)
        self.vt = nil
        self.screen = nil
    end
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
    self.view = nil
end

return VTermPlugin
