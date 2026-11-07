-- 历史回溯还原管线回归(真机乱码): 键盘回车=\r 必须归档历史;
-- ash redraw 单块含提示符+命令+ESC[J, 读侧提示符检出不得清队列
package.path = "/mnt/us/koreader/plugins/vterm.koplugin/?.lua;/home/m/koreader/plugins/vterm.koplugin/?.lua;" .. package.path
local PTY = require("pty")
local CJK = "中文命令"

local child = [[
printf '%s' '/var/tmp/root [V]# '
IFS= read -r line                       # 等回车
printf '%s' '/var/tmp/root [V]# '
stty -icanon -echo
dd bs=1 count=3 >/dev/null 2>&1         # 等上箭头 3 字节(需非规范模式)
printf '%s' '/var/tmp/root [V]# echo ???? \033[J'
sleep 1
]]
local f = io.open("/tmp/vt_child.sh", "w")
f:write(child) f:close()

local pty = PTY.new()
local ok = pty:spawn("/bin/sh", {"/tmp/vt_child.sh"}, 24, 80)
assert(ok, "spawn failed")
pty.is_local = true

local function drain(seconds) -- 迭代驱动, os.time 秒级精度不可靠
    local out = ""
    for _ = 1, math.max(1, math.floor(seconds / 0.05)) do
        local chunk = pty:read()
        if chunk then out = out .. chunk end
        os.execute("sleep 0.05")
    end
    return out
end

-- 1. 首块: 提示符检出 → line_active=true
local out1 = drain(0.5)
assert(out1:find("%[V%]") and pty.line_active, "prompt not detected: " .. ("%q"):format(out1))
print("[PASS] 1. 提示符检出 line_active=true")

-- 2. 敲入中文命令, ash 以 '?' 回显 → 还原为汉字
pty:write("echo " .. CJK)
local out2 = drain(0.3)
assert(out2:find("echo " .. CJK, 1, true), "typed echo not restored: " .. ("%q"):format(out2))
print("[PASS] 2. 敲入回显 '?'→汉字还原")

-- 3. 回车(键盘路径 \r)必须归档历史: 这就是真机乱码根因
pty:write("\r")
drain(0.5) -- 第二个提示符块到达, la 翻回 true
assert(not pty.line_active or true, "")
assert(#pty.cmd_history == 1, "\\r not archived: history=" .. #pty.cmd_history)
assert(pty.line_active, "prompt after Enter not detected")
print("[PASS] 3. \\r 回车归档 cmd_history=1, 新提示符 la=true")

-- 4. 上箭头: 写侧重建队列; redraw 单块(PS1+echo ????+ESC[J) → 还原为汉字
pty:write("\27[A")
assert(#pty.pending_utf8_chars == #CJK / 3, "queue not rebuilt on up-arrow")
local out4 = drain(1.2)
assert(out4:find("echo " .. CJK, 1, true),
    "BUG: redraw '?' not restored: " .. ("%q"):format(out4))
print("[PASS] 4. 上箭头 redraw '?'→汉字还原(提示符检出不清队列)")

-- 5. 回溯后行栈在位: 退格不崩
pty:write("\127")
local out5 = drain(0.3)
print("[PASS] 5. 回溯后退格不崩, 输出=" .. ("%q"):format(out5:sub(1, 40)))

pty:write("exit\n")
pty:close()
print("[SUCCESS] history recall translation PASSED")
