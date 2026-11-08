local ffi = require("ffi")
local C = ffi.C

ffi.cdef[[
typedef int pid_t;
typedef long ssize_t;

int grantpt(int fd) __attribute__((nothrow, leaf));
int unlockpt(int fd) __attribute__((nothrow, leaf));
char *ptsname(int fd) __attribute__((nothrow, leaf));
pid_t setsid(void) __attribute__((nothrow, leaf));
pid_t fork(void) __attribute__((nothrow, leaf));
int dup2(int oldfd, int newfd) __attribute__((nothrow, leaf));
int close(int fd);
int open(const char *pathname, int flags, ...);
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int kill(pid_t pid, int sig) __attribute__((nothrow, leaf));
pid_t waitpid(pid_t pid, int *status, int options);
int setenv(const char *name, const char *value, int overwrite) __attribute__((nothrow, leaf));
int execvp(const char *file, char *const argv[]);

struct winsize {
    unsigned short ws_row;
    unsigned short ws_col;
    unsigned short ws_xpixel;
    unsigned short ws_ypixel;
};
int ioctl(int fd, unsigned long request, ...);

struct termios {
    unsigned int c_iflag;
    unsigned int c_oflag;
    unsigned int c_cflag;
    unsigned int c_lflag;
    unsigned char c_line;
    unsigned char c_cc[32];
    unsigned int c_ispeed;
    unsigned int c_ospeed;
};
int tcgetattr(int fd, struct termios *termios_p);
int tcsetattr(int fd, int optional_actions, const struct termios *termios_p);
]]

local O_RDWR = 2
local O_NONBLOCK = 0x800
local TIOCSWINSZ = 0x5414
local WNOHANG = 1
local SIGTERM = 15
local IUTF8 = 0x4000 -- Linux c_iflag: 一次退格擦除整个 UTF-8 字符(中文退格不烂行)
local ICANON = 0x2 -- c_lflag: 行规程 canonical 模式(shell 读行); raw 应用(vi/ssh)会关掉
local TCSANOW = 0

local PTY = {}
PTY.__index = PTY

-- 临时排障开关: VTERM_DEBUG_ECHO=1 时把 PTY 双向字节流 + 队列长度落盘。
-- 首次调用覆盖写(不留上次的敏感残留——流里可能含手打密码/token), 之后追加。
local DEBUG_ECHO = os.getenv("VTERM_DEBUG_ECHO") == "1"
    or (function()
        -- 真机排障通道: KUAL 启动无法注入环境变量, 插件目录放 echo.dbg.on 即开
        local f = io.open("/mnt/us/koreader/plugins/vterm.koplugin/echo.dbg.on", "r")
        if f then f:close() return true end
        return false
    end)()
local TRACE = os.getenv("VTERM_DEBUG_ECHO") == "1" -- 临时: 与 echo 日志同开关
local SYNTH_ON = os.getenv("VTERM_NO_SYNTH") ~= "1" -- 临时 A/B 开关(基线对比)
local ECHO_LOG = "/mnt/us/koreader/plugins/vterm.koplugin/echo.log"
local echo_log_started = false
local function dbg(fmt, ...)
    if not DEBUG_ECHO then return end
    local f = io.open(ECHO_LOG, echo_log_started and "a" or "w")
    if f then
        f:write(string.format(fmt, ...), "\n")
        f:close()
        echo_log_started = true
    end
end

function PTY.new()
    local self = setmetatable({}, PTY)
    self.master_fd = -1
    self.child_pid = -1
    self.slave_name = nil
    self.buffer = ffi.new("char[8192]")
    self.pending_utf8_chars = {} -- 队列：记录本地写入的完整 UTF-8 多字节字符(? 回显还原)
    self.line_stack = {}         -- 栈：本行已写入的全部字符(擦除组翻译用)
    self.line_active = false     -- 是否在 shell 提示符行(见读侧提示符检测)
    self.pending_line = {}       -- 本行字符序列(回车时归档进命令历史)
    self.cmd_history = {}        -- 含宽字符的历史命令(字符数组栈, 上限 50)
    self.hist_idx = nil          -- 当前回溯位置(1=最旧)
    self.read_carry = ""         -- 跨读块被截断的擦除组前缀
    self.vdet_carry = ""         -- 跨读块被截断的 [V] 提示符检测尾巴
    self.is_local = false
    self.native_shell = false    -- true=本地 shell 是插件 Unicode busybox(行编辑
                                 -- 回显已是真 UTF-8, 跳过全部抑制/翻译/还原层)
    self.byte_level_editor = nil -- true=字节级编辑器(busybox vi); false=字符级(utf8 vim); nil=保守按字节
    -- 影子行合成(真机乱码根治): local+line_active 时写侧已知行内容/光标,
    -- 合成网格重绘字节, 读侧抑制 lineedit 回显(其 ? 回显/1 列光标模型与
    -- vterm 2 列汉字错位 = ←/⌫ 乱码根因; 真机 ash 探针实证)
    self.shadow = {}             -- 影子行字符(1..n, 与网格渲染一致)
    self.scur = 0                -- 影子光标(光标前字符数, 0..n)
    self.synth = ""              -- 待发合成重绘字节
    self.hist_mode = false       -- 保留字段(旧版历史编辑态, 现全部数据驱动)    self.cr_pending = false      -- 回车已发等 \n 回显(期间抑制尾行重印)
    return self
end

function PTY:spawn(shell_cmd, args, rows, cols, env_vars)
    rows = rows or 24
    cols = cols or 80

    local master_fd = C.open("/dev/ptmx", bit.bor(O_RDWR, O_NONBLOCK))
    if master_fd < 0 then
        return false, "Failed to open /dev/ptmx"
    end

    if C.grantpt(master_fd) < 0 then
        C.close(master_fd)
        return false, "grantpt failed"
    end
    if C.unlockpt(master_fd) < 0 then
        C.close(master_fd)
        return false, "unlockpt failed"
    end

    local pts_name_ptr = C.ptsname(master_fd)
    if pts_name_ptr == nil then
        C.close(master_fd)
        return false, "ptsname failed"
    end
    local slave_name = ffi.string(pts_name_ptr)
    self.master_fd = master_fd
    self.slave_name = slave_name

    self:setWindowSize(rows, cols)

    local pid = C.fork()
    if pid < 0 then
        C.close(master_fd)
        return false, "fork failed"
    elseif pid == 0 then
        C.close(master_fd)
        C.setsid()

        local slave_fd = C.open(slave_name, O_RDWR)
        if slave_fd >= 0 then
            C.dup2(slave_fd, 0)
            C.dup2(slave_fd, 1)
            C.dup2(slave_fd, 2)
            C.ioctl(slave_fd, 0x540E, 0) -- TIOCSCTTY: 设为控制终端(bash -i 无 job control 警告)
            if slave_fd > 2 then
                C.close(slave_fd)
            end
        end

        C.setenv("TERM", "xterm-256color", 1)
        C.setenv("COLORTERM", "truecolor", 1)
        C.setenv("LANG", "C.UTF-8", 1)
        C.setenv("LC_ALL", "C.UTF-8", 1)

        if env_vars then
            for k, v in pairs(env_vars) do
                C.setenv(tostring(k), tostring(v), 1)
            end
        end

        local argv_list = { shell_cmd }
        if args then
            for _, arg in ipairs(args) do
                table.insert(argv_list, arg)
            end
        end

        local c_argv = ffi.new("char*[?]", #argv_list + 1)
        for i, arg in ipairs(argv_list) do
            c_argv[i - 1] = ffi.cast("char*", arg)
        end
        c_argv[#argv_list] = nil

        C.execvp(shell_cmd, c_argv)
        os.exit(127)
    end

    self.child_pid = pid
    self:setUtf8()
    return true, pid
end

-- 置 IUTF8: 行规程按字符(而非字节)擦除, shell 行内退格中文不错位。
-- ⚠️ bash -i 启动后会整体重设 termios 把 IUTF8 清掉(真机探针实证),
-- 故须在每次 write 前重申。
function PTY:setUtf8()
    if self.master_fd < 0 then return end
    local t = ffi.new("struct termios")
    if C.tcgetattr(self.master_fd, t) == 0 then
        t.c_iflag = bit.bor(t.c_iflag, IUTF8)
        C.tcsetattr(self.master_fd, TCSANOW, t)
    end
end

-- 检查并补挂 IUTF8: 返回 true 表示本次调用有重新设置
function PTY:ensureUtf8()
    if self.master_fd < 0 then return false end
    local t = ffi.new("struct termios")
    if C.tcgetattr(self.master_fd, t) ~= 0 then return false end
    if bit.band(t.c_iflag, IUTF8) == 0 then
        t.c_iflag = bit.bor(t.c_iflag, IUTF8)
        C.tcsetattr(self.master_fd, TCSANOW, t)
        return true
    end
    return false
end

-- 前台是否处于 canonical 行模式(true=shell 在读行; false=raw 全屏应用如 vi)
function PTY:isCanonical()
    if self.master_fd < 0 then return true end
    local t = ffi.new("struct termios")
    if C.tcgetattr(self.master_fd, t) ~= 0 then return true end
    return bit.band(t.c_lflag, ICANON) ~= 0
end

function PTY:setWindowSize(rows, cols)
    self.grid_cols = cols -- 合成重绘换行感知用(与 view 网格同步)
    if self.master_fd < 0 then return end
    local ws = ffi.new("struct winsize")
    ws.ws_row = rows
    ws.ws_col = cols
    ws.ws_xpixel = 0
    ws.ws_ypixel = 0
    C.ioctl(self.master_fd, TIOCSWINSZ, ws)
end

function PTY:read()
    if self.master_fd < 0 then return nil end
    -- 合成重绘优先冲刷: 不依赖回显字节捎带(⌫ 后可能无任何回显, 滞留会
    -- 错过断言/刷新窗口)
    if self.synth and self.synth ~= "" then
        local s = self.synth
        self.synth = ""
        return s
    end
    local n = C.read(self.master_fd, self.buffer, 8192)
    if n > 0 then
        local raw = (self.read_carry or "") .. ffi.string(self.buffer, n)
        self.read_carry = ""
        -- 鼠标上报模式跟踪: 应用(vim mouse=a 等)用 DECSET ?1000/1002(+1006 SGR)
        -- 开关鼠标事件。libvterm 不暴露该状态 → 直接扫输出流(末尾留跨块拼接
        -- 余量防序列被切半)。vterm_view 据此把触摸翻译成 SGR 鼠标序列。
        do
            local mcarry = (self.mouse_carry or ""):sub(-12) .. raw
            self.mouse_carry = mcarry
            for mode, en in mcarry:gmatch("\27%[(%?10%d%d)([hl])") do
                local num = tonumber(mode:sub(2))
                if num == 1000 then
                    self.mouse_click = en == "h"
                elseif num == 1002 then
                    -- 1002 = 点击+拖动超集(远端 vim ttymouse=xterm2 时只发 1002
                    -- 不发 1000), 必须同时点亮点击, 否则触摸全被忽略
                    self.mouse_drag = en == "h"
                    self.mouse_click = en == "h"
                elseif num == 1006 then
                    self.mouse_sgr = en == "h"
                end
            end
        end
        if self.is_local then
            dbg("R %q q=%d st=%d la=%s", raw, #self.pending_utf8_chars,
                #self.line_stack, tostring(self.line_active))
        end
        -- 本地会话回显翻译层:
        --  ⓪ 提示符检测: PS1 内嵌 [V] 标记, 检出即重新激活行模式(shell 等待
        --     输入); 回车后失效直到下一个提示符 → vi 等全屏应用内栈为空。
        --  ① shell 的擦除组(\b \b 或 \b ESC[J)按"1 组 = 1 字符"翻译: 从行字符栈
        --     弹出被删字符, 宽字符(汉字占 2 列)把组复制一份清两列, 否则 shell 的
        --     1 列/字符 模型与 vterm 的 2 列/汉字 错位 → 删除残影/命令错乱。
        --  ② '?' 回显(busybox lineedit 非 unicode 模式每字符回显一个 ?)还原为
        --     真实汉字。
        if self.is_local then
            -- [V] 提示符检测 + 跨块截断防护: 提示符可能被切在两个读块
            -- ([V|]$ ), 检不出则行激活永远为假 → 合成/翻译全失效(真机乱码)。
            -- 未检出时扣留末 3 字节与下块拼接。
            -- native 透传模式同样需要行激活跟踪: delChar 的退格粒度与
            -- _feedVterm 的字节列换算都按 lineActive() 分派。
            if (SYNTH_ON or self.native_shell) and not self.line_active then
                raw = (self.vdet_carry or "") .. raw
                self.vdet_carry = ""
                if raw:find("%[V%]") then
                    self.line_active = true
                    self.shadow = {}
                    self.scur = 0
                    -- 学习提示符显示宽度(合成重绘的换行定位基准): 取块内
                    -- 最后一行并剥掉转义序列(如行尾 ESC[6n), ASCII 字节数=列数
                    local last = raw:match("([^\n]*)$") or ""
                    last = last:gsub("\27%[[%d;]*[A-Za-z]", "")
                    if #last > 0 and #last < 200 then self.prompt_cols = #last end
                    if TRACE then
                        local f = io.open("/tmp/vt_synth.log", "a")
                        if f then
                            f:write(string.format("PV raw=%q last=%q pw=%s\n",
                                raw:sub(1, 40), last, tostring(#last)))
                            f:close()
                        end
                    end
                    -- 检出块整块放行: 提示符本身必须画到网格上(抑制会吃掉
                    -- "[V]$ " 造成行基准错位 → 后续合成整体偏移)
                    return raw
                elseif raw:sub(-2) == "[V" then
                    self.vdet_carry = "[V"
                    raw = raw:sub(1, #raw - 2)
                elseif raw:sub(-1) == "[" then
                    self.vdet_carry = "["
                    raw = raw:sub(1, #raw - 1)
                end
            end
            if self.native_shell then
                -- 原生透传: 插件 Unicode busybox 的行编辑回显/退格/历史全部
                -- 真 UTF-8 且按显示列移动光标。旧翻译层按"1 擦除组=1 字符"
                -- 弹行栈, 会把宽字符退格(2 列/字)拆错; ? 还原队列也失去意义
                -- (滞留队列反而会把用户敲的真 '?' 顶成汉字) → 全部跳过。
                return raw
            end
            if TRACE then
                local f = io.open("/tmp/vt_synth.log", "a")
                if f then
                    f:write(string.format("RD la=%s crp=%s n=%d raw=%q\n",
                        tostring(self.line_active), tostring(self.cr_pending), n, raw:sub(1, 16)))
                    f:close()
                end
            end
            if SYNTH_ON and self.cr_pending then
                -- 回车已发: 抑制 lineedit 的尾行重印(真 UTF-8 会话)直到 \n,
                -- \n 起的执行输出放行
                local nl = raw:find("\n", 1, true)
                if not nl then return "" end
                self.cr_pending = false
                self.line_active = false
                self.shadow = {}
                self.scur = 0
                -- 回车回显统一补 \r: 部分 shell/lineedit 只回裸 \n(LF), 网格收到
                -- 裸 LF 只下移不回列 → 提示符逐行右移错位(真机"回车后不对齐")。
                -- 原块里的 \r(若有)在此连同前面的尾行重印一起丢弃, 统一重建。
                raw = "\r\n" .. raw:sub(nl + 1)
                -- \n 后的剩余部分同样可能含新提示符(输出与提示符同块):
                -- 必须重新检测, 否则行激活保持假 → 检测 carry 吞字节/合成全失效
                if raw:find("%[V%]") then
                    self.line_active = true
                    return raw
                end
            elseif SYNTH_ON and self.line_active then
                -- 行激活期: lineedit 回显抑制, 仅放行 ESC[6n 光标查询。
                -- 执行输出常与新提示符同一读块到达: 按块内最后一个 [V] 切分,
                -- 之前的输出放行(否则报错/异步输出被吞), 提示符起抑制
                local vpos = raw:match(".*%[V%][#$]%s()")
                local head = ""
                if vpos then
                    head = raw:sub(1, vpos - 1)
                    raw = raw:sub(vpos)
                end
                local kept, p, l = {}, 1, #raw
                while p <= l do
                    local s = raw:find("\27[6n", p, true)
                    if not s then break end
                    kept[#kept + 1] = raw:sub(s, s + 3)
                    p = s + 4
                end
                return head .. table.concat(kept)
            end
            local out, pos, len = {}, 1, #raw
            while pos <= len do
                local b = raw:byte(pos)
                if b == 8 then -- \b: 收集连续擦除组并按字符栈翻译
                    local kind, groups, p, incomplete = nil, 0, pos, false
                    while p <= len do
                        if raw:byte(p) ~= 8 then break end
                        local c2 = raw:byte(p + 1)
                        if c2 == nil then incomplete = true break end
                        if c2 == 27 then
                            local c3, c4 = raw:byte(p + 2), raw:byte(p + 3)
                            if c3 == nil or c4 == nil then incomplete = true break end
                            if c3 == 0x5B and c4 == 0x4A then
                                if kind == "bs" then break end
                                kind, groups = "escj", groups + 1
                                p = p + 4
                            else
                                break
                            end
                        elseif c2 == 32 then
                            local c3 = raw:byte(p + 2)
                            if c3 == nil then incomplete = true break end
                            if c3 == 8 then
                                if kind == "escj" then break end
                                kind, groups = "bs", groups + 1
                                p = p + 3
                            else
                                break
                            end
                        else
                            break
                        end
                    end
                    if groups == 0 and incomplete then
                        -- 读块在擦除组中间截断: 暂存, 与下一块拼齐再翻译,
                        -- 否则半组会被当裸 \b 只擦 1 列 → 宽字符残留
                        self.read_carry = raw:sub(pos)
                        pos = len + 1
                    elseif groups == 0 then
                        out[#out + 1] = string.char(8) -- 裸 \b = 光标移动
                        pos = pos + 1
                    else
                        -- 弹 groups 个字符算 vterm 总宽(汉字 2 列)
                        local W, n = 0, 0
                        while n < groups and #self.line_stack > 0 do
                            local ch = table.remove(self.line_stack)
                            W = W + ((#ch > 1) and 2 or 1)
                            n = n + 1
                        end
                        W = W + (groups - n) -- 栈弹尽后剩余组 = 提示符区 ASCII
                        if kind == "escj" then
                            out[#out + 1] = string.rep("\8", W) .. "\27[J"
                        else
                            out[#out + 1] = string.rep("\8 \8", W)
                        end
                        pos = p
                    end
                elseif b == 63 and self.line_active and #self.pending_utf8_chars > 0 then
                    out[#out + 1] = table.remove(self.pending_utf8_chars, 1)
                    pos = pos + 1
                elseif b >= 0xC0 then
                    -- 真实 UTF-8 回显(装好 locale 的 readline 按字符回显):
                    -- 与还原队列队首对齐后出队。否则队列长期滞留, 会把用户
                    -- 随后敲的 '?' 顶成汉字(乱码)。
                    local blen = (b >= 0xF0) and 4 or ((b >= 0xE0) and 3 or 2)
                    local seq = raw:sub(pos, pos + blen - 1)
                    if #seq == blen and self.pending_utf8_chars[1] == seq then
                        table.remove(self.pending_utf8_chars, 1)
                        dbg(" drain %q q=%d", seq, #self.pending_utf8_chars)
                    end
                    out[#out + 1] = seq
                    pos = pos + #seq
                else
                    out[#out + 1] = raw:sub(pos, pos)
                    pos = pos + 1
                end
            end
            return table.concat(out)
        end
        return raw
    elseif n == 0 then
        return ""
    else
        return nil
    end
end

function PTY:write(data)
    if self.master_fd < 0 or not data or #data == 0 then return end
    -- bash 重设 termios 会清 IUTF8, 写入前补挂(退格整字擦除的前提)
    self:ensureUtf8()
    if self.is_local and self.native_shell then
        -- 原生透传: 不做影子行/还原队列/行栈/历史拦截, 字节直写。
        -- 行激活跟踪仅服务退格粒度分派(delChar/_feedVterm): 回车即失效,
        -- 下一个 [V] 提示符由读侧重新检出。
        dbg("WN %q la=%s", data, tostring(self.line_active))
        if self.line_active
            and (data:find("\r", 1, true) or data:find("\n", 1, true)) then
            self.line_active = false
        end
        return C.write(self.master_fd, data, #data)
    end
    if self.is_local then
        -- 影子行合成: 写入字节 = shell 实收字节, 影子行按数据自带 ops 演进
        -- (↑/↓ 由下方历史重建块接管); 视图侧无需同步 — 原始 sendBytes 写入
        -- (命令文本/别名) 与草稿缓冲写入语义天然一致
        if SYNTH_ON and self.line_active and not self.cr_pending then
            self:_dataEdit(data)
        end
        if data:find("\r", 1, true) or data:find("\n", 1, true) then
            -- 回车: 行激活保持到读侧见到 \n(抑制尾行重印), 期间不再合成
            self.cr_pending = self.line_active
        end
        dbg("W %q la=%s q=%d st=%d", data, tostring(self.line_active),
            #self.pending_utf8_chars, #self.line_stack)
        if TRACE then
            local f = io.open("/tmp/vt_synth.log", "a")
            if f then
                f:write(string.format("W la=%s crp=%s hm=%s sync=%s data=%q\n",
                    tostring(self.line_active), tostring(self.cr_pending),
                    tostring(self.hist_mode), tostring(false), data:sub(1, 12)))
                f:close()
            end
        end
    end
    -- 行字符栈: 仅在 shell 提示符行(line_active)记录已写入字符, 供读侧擦除
    -- 组翻译; 回车后失效, 直到检出提示符标记。vi 等全屏应用内不压栈(它们
    -- 是字节级/自绘编辑器, 栈语义不成立)。
    -- 多字节字符同时入 '?' 还原队列
    if self.is_local and self.line_active then
        local i = 1
        while i <= #data do
            local b = data:byte(i)
            if b == 27 then
                -- ANSI 转义序列(方向键/Home 等)整体跳过: 它们不是行内可见
                -- 字符, 入栈会让擦除组翻译弹错字符 → 宽字符删不干净
                local j = i + 1
                if data:byte(j) == 0x5B then -- '['
                    j = j + 1
                    while j <= #data do
                        local c = data:byte(j)
                        if c >= 0x40 and c <= 0x7E then break end
                        j = j + 1
                    end
                end
                i = j + 1
            elseif b >= 0xC0 then
                local len = (b >= 0xF0) and 4 or ((b >= 0xE0) and 3 or 2)
                if i + len - 1 <= #data then
                    local uchar = data:sub(i, i + len - 1)
                    table.insert(self.line_stack, uchar)
                    table.insert(self.pending_utf8_chars, uchar)
                    table.insert(self.pending_line, uchar)
                    i = i + len
                else
                    i = #data + 1 -- 被截断的多字节序列(极罕见): 丢弃残片
                end
            elseif b == 10 or b == 13 then -- 回车: 键盘路径 addChars 已把 \n 转成 \r, 两者都要归档
                self.line_stack = {}
                self.pending_utf8_chars = {}
                -- line_active 保持 true 到读侧 \n(抑制尾行重印), 由读侧复位
                self.hist_idx = nil
                local nchars = #self.pending_line
                if nchars > 0 then
                    -- 全部命令都入写侧历史: line_active 期 shell 回显被抑制,
                    -- ↑/↓ 的整行重绘全靠这里合成。只记宽字符会让 ASCII 命令
                    -- 回溯无显示, 且 hist_idx 与 shell 实际历史错位(屏上命令
                    -- ≠ shell 行上的命令, 回车执行的与看到的不一致)。
                    table.insert(self.cmd_history, self.pending_line)
                    if #self.cmd_history > 50 then table.remove(self.cmd_history, 1) end
                end
                self.pending_line = {}
                i = i + 1
            elseif b >= 32 and b <= 126 then
                -- 可见 ASCII 字符入栈(擦除组按字符计数翻译的前提); 其它控制
                -- 字符(含 Tab)不入栈, 它们不产生行内可见字符
                table.insert(self.line_stack, string.char(b))
                table.insert(self.pending_line, string.char(b))
                self.hist_idx = nil
                i = i + 1
            elseif b == 127 or b == 8 then
                -- 退格: 行模型长度 -1(屏幕擦除交给读侧擦除组翻译, 栈勿在此弹,
                -- 否则会被弹两次)。还原队列也不动: 若该字已被回显, 队列里本来
                -- 就没有它; 若回显还在路上, 保留它才能正确还原。
                if #self.pending_line > 0 then
                    table.remove(self.pending_line)
                end
                i = i + 1
            elseif b == 21 then -- Ctrl-U: 删到行首 → 整行内容与还原队列一起清空
                self.pending_line = {}
                self.pending_utf8_chars = {}
                i = i + 1
            elseif b == 23 then -- Ctrl-W: 删前一个词
                while #self.pending_line > 0 do
                    local ch = table.remove(self.pending_line)
                    if ch == " " then break end
                end
                self.pending_utf8_chars = {}
                i = i + 1
            else
                i = i + 1
            end
        end
        -- 方向键历史回溯: \x1b[A=上一条(越按越早, 到顶停留), \x1b[B=下一条
        -- (向新; 越过最新一条=shell 回到空行); shell 将整条命令按字符重绘
        -- (中文=1 个 ?), 用历史命令重建还原队列。行字符栈也必须按历史命令
        -- 重建 —— 否则栈里残留旧行字符, 回溯后按退格会弹错宽度删不干净。
        local up = data:find("\27[A", 1, true) ~= nil
        local down = data:find("\27[B", 1, true) ~= nil
        if up or down then
            local n = #self.cmd_history
            local browsing = self.hist_idx ~= nil
            if up and n > 0 then
                self.hist_idx = self.hist_idx and math.max(self.hist_idx - 1, 1) or n
            elseif down and self.hist_idx then
                self.hist_idx = self.hist_idx + 1
                if self.hist_idx > n then self.hist_idx = nil end -- 越过最新=空行
            end
            local cmd = self.hist_idx and self.cmd_history[self.hist_idx]
            if cmd or (down and browsing) then
                local pre, pcur = self.shadow, self.scur
                self.line_stack = {}
                self.pending_utf8_chars = {}
                self.pending_line = {}
                self.shadow = {}
                for _, ch in ipairs(cmd or {}) do
                    table.insert(self.line_stack, ch)
                    table.insert(self.pending_line, ch)
                    self.shadow[#self.shadow + 1] = ch
                    if #ch > 1 then table.insert(self.pending_utf8_chars, ch) end
                end
                self.scur = #self.shadow
                self:_emitRepaint(pre, pcur, self.shadow, self.scur)
            end
        end
    end
    return C.write(self.master_fd, data, #data)
end

-- 数据驱动影子行编辑: 写入字节即 shell 实收字节, 可见字符插入光标处,
-- ⌫ 删光标前字符, 方向键移动光标, Ctrl-U 删到行首, Ctrl-W 删前一个词。
-- (↑/↓ 历史由调用侧重建块接管, 这里跳过 ESC[A/B)
function PTY:_dataEdit(data)
    local pre, pcur = self.shadow, self.scur
    local pre_copy = {}
    for _, ch in ipairs(pre) do pre_copy[#pre_copy + 1] = ch end
    local i, changed = 1, false
    while i <= #data do
        local b = data:byte(i)
        if b == 27 then
            -- 转义序列: 光标类按字符位移, 历史键由重建块处理, 其余跳过
            if data:byte(i + 1) == 0x5B then
                local c = data:byte(i + 2)
                if c == 0x44 then -- ESC[D 左
                    if self.scur > 0 then self.scur = self.scur - 1 end
                    changed = true
                    i = i + 3
                elseif c == 0x43 then -- ESC[C 右
                    if self.scur < #self.shadow then self.scur = self.scur + 1 end
                    changed = true
                    i = i + 3
                elseif c == 0x48 then -- ESC[H 行首
                    self.scur = 0
                    changed = true
                    i = i + 3
                elseif c == 0x46 then -- ESC[F 行尾
                    self.scur = #self.shadow
                    changed = true
                    i = i + 3
                else
                    local j = i + 2
                    while j <= #data do
                        local cc = data:byte(j)
                        if cc >= 0x40 and cc <= 0x7E then break end
                        j = j + 1
                    end
                    i = j + 1
                end
            else
                i = i + 1
            end
        elseif b >= 0xC0 then
            local len = (b >= 0xF0) and 4 or ((b >= 0xE0) and 3 or 2)
            if i + len - 1 <= #data then
                table.insert(self.shadow, self.scur + 1, data:sub(i, i + len - 1))
                self.scur = self.scur + 1
                changed = true
                i = i + len
            else
                i = #data + 1
            end
        elseif b >= 32 then
            if b ~= 127 then
                table.insert(self.shadow, self.scur + 1, string.char(b))
                self.scur = self.scur + 1
                changed = true
            elseif self.scur > 0 then
                table.remove(self.shadow, self.scur)
                self.scur = self.scur - 1
                changed = true
            end
            i = i + 1
        elseif b == 8 then
            if self.scur > 0 then
                table.remove(self.shadow, self.scur)
                self.scur = self.scur - 1
                changed = true
            end
            i = i + 1
        elseif b == 21 then -- Ctrl-U: 删行首到光标
            for _ = 1, self.scur do table.remove(self.shadow, 1) end
            self.scur = 0
            changed = true
            i = i + 1
        elseif b == 23 then -- Ctrl-W: 删光标前一个词
            while self.scur > 0 do
                local ch = table.remove(self.shadow, self.scur)
                self.scur = self.scur - 1
                changed = true
                if ch == " " then break end
            end
            i = i + 1
        else
            i = i + 1
        end
    end
    if changed then self:_emitRepaint(pre_copy, pcur, self.shadow, self.scur) end
end

-- 合成重绘: 网格光标移到行首 → 重画整行 → 擦净尾部 → 光标回到行内位置
-- 不变式: 每次合成后网格光标 = 提示符宽 + 影子行前 scur 个字符的宽度
function PTY:_emitRepaint(pre, pcur, new, ncur)
    if TRACE then
        local f = io.open("/tmp/vt_synth.log", "a")
        if f then
            f:write(string.format("R pre=%d/%d new=%d/%d cols=%s pw=%s\n",
                #pre, pcur, #new, ncur, tostring(self.grid_cols), tostring(self.prompt_cols)))
            f:close()
        end
    end
    local wsum = function(list, upto)
        local w = 0
        for i = 1, math.min(upto or 0, #list) do
            w = w + ((#list[i] > 1) and 2 or 1)
        end
        return w
    end
    local cols = self.grid_cols
    local pw = self.prompt_cols
    local out = {}
    if cols and cols > 8 and pw then
        -- 换行感知重绘(绝对定位): 提示符+行宽超过终端列数时命令行折行,
        -- \b 在列 0 被钳住无法跨行回退(全程用 \b 会让光标落到错误行 →
        -- 真机整屏错乱)。统一用 \r + CUU/CUD + CUF 做绝对定位, 提示符自身
        -- 折行(pw ≥ cols)同样成立。
        -- ponytail: 清旧尾用的 ESC[B 在屏幕末行会触发滚动(长行删短且贴底),
        -- 该场景屏幕整体上移一行; 真实使用罕见, 出现再加屏幕行号跟踪。
        -- 折行悬挂语义: 写完第 cols 列时光标仍停在最后一列(pending wrap),
        -- 行号取 floor(p/cols)-1, 列取 cols-1。
        local function rr(p)
            if p > 0 and p % cols == 0 then return math.floor(p / cols) - 1, cols - 1 end
            return math.floor(p / cols), p % cols
        end
        -- 从 (fr 行) 绝对定位到位置 to(列口径, 从行首算)
        local function move_to(fr, to)
            local tr, tc = math.floor(to / cols), to % cols
            out[#out + 1] = "\r"
            if fr > tr then
                out[#out + 1] = string.format("\27[%dA", fr - tr)
            elseif tr > fr then
                out[#out + 1] = string.format("\27[%dB", tr - fr)
            end
            if tc > 0 then out[#out + 1] = string.format("\27[%dC", tc) end
            return tr
        end
        local pos_old = pw + wsum(pre, pcur)
        local end_new = pw + wsum(new, #new)
        local end_old = pw + wsum(pre, #pre)
        local target = pw + wsum(new, ncur)
        local r_old = rr(pos_old)
        move_to(r_old, 0)        -- 到行首(提示符第一个字符)
        move_to(0, pw)           -- 到内容起点(提示符之后, 支持提示符自身折行)
        for _, ch in ipairs(new) do out[#out + 1] = ch end
        -- 行宽恰好填满最后一列时终端处于 pending-wrap: 光标仍停在最后一个
        -- 字符格上, 此时 ESC[K 会把该字符一起擦掉(命令把本行写满时, 历史
        -- 回溯尾部少一个字符)。该行右侧没有残留, 直接跳过擦除。
        if not (end_new > 0 and end_new % cols == 0) then
            out[#out + 1] = "\27[K"  -- 清本行新尾之后的残留
        end
        -- 旧行更长时逐行下清残尾, 光标停在清理的最后一行行首
        local cur_row = rr(end_new)
        local r_old_end = rr(end_old)
        while cur_row < r_old_end do
            out[#out + 1] = "\r\27[B\27[K"
            cur_row = cur_row + 1
        end
        move_to(cur_row, target) -- 绝对定位到光标
        self.synth = (self.synth or "") .. table.concat(out)
        return
    end
    local back = wsum(pre, pcur)
    if back > 0 then out[#out + 1] = string.rep("\b", back) end
    for _, ch in ipairs(new) do out[#out + 1] = ch end
    out[#out + 1] = "\27[J"
    local fwd = wsum(new, ncur)
    if fwd > 0 then out[#out + 1] = string.rep("\b", fwd) end
    self.synth = (self.synth or "") .. table.concat(out)
end

-- 行字符栈是否为空(空 = 不在 shell 提示符行, 如 vi 内部 → 字节级退格)
function PTY:lineStackEmpty()
    return #self.line_stack == 0
end

-- 是否处于 shell 提示符行(提示符标记 [V] 激活, 回车失效)
function PTY:lineActive()
    return self.line_active == true
end

function PTY:isAlive()
    if self.child_pid <= 0 then return false end
    local status = ffi.new("int[1]")
    local res = C.waitpid(self.child_pid, status, WNOHANG)
    if res == self.child_pid then
        self.child_pid = -1
        return false
    end
    return true
end

function PTY:close()
    if self.child_pid > 0 then
        C.kill(self.child_pid, SIGTERM)
        local status = ffi.new("int[1]")
        C.waitpid(self.child_pid, status, WNOHANG)
        self.child_pid = -1
    end
    if self.master_fd >= 0 then
        C.close(self.master_fd)
        self.master_fd = -1
    end
end

-- 收割上次异常退出残留的 shell(KOReader 崩溃/被杀时 closeTerminal 没跑):
-- 直接 TERM 子进程(shell 死后 PTY master 关闭, 内核给前台进程组补 SIGHUP)。
-- 返回 true=确有残留并已收割。
function PTY.reapStale(pid)
    if not pid or pid <= 1 then return false end
    if C.kill(pid, 0) ~= 0 then return false end -- 探活: 进程不存在则 ESRCH
    C.kill(pid, SIGTERM)
    return true
end

return PTY
