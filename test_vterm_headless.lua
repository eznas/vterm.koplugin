package.path = "/home/m/koreader/plugins/vterm.koplugin/?.lua;" .. package.path

print("[TEST-HEADLESS] 1. Loading KOReader environment and mock objects...")
local ffi = require("ffi")

-- 引入基础模块
local VTermFFI = require("vterm_ffi")
local PTY = require("pty")

print("[TEST-HEADLESS] 2. Verifying VTermFFI with libvterm...")
local vt_lib = VTermFFI.load("/home/m/koreader/plugins/vterm.koplugin")
assert(vt_lib, "libvterm failed to load")

local vt, screen = VTermFFI.newTerminal(vt_lib, 24, 80)
assert(vt and screen, "Terminal instance creation failed")

print("[TEST-HEADLESS] 3. Testing PTY spawn and stream bridge...")
local pty = PTY.new()
local ok, pid = pty:spawn("/bin/sh", nil, 24, 80)
assert(ok, "PTY spawn failed")

-- 写入测试命令，包含颜色、中文、Vim 状态序列
local cmd = "printf \"\033[32m[PASS]\033[0m 终端中文测试: 你好KOReader\r\n\"\n"
pty:write(cmd)

-- 收集 PTY 数据并写入 libvterm
local collected = ""
for i = 1, 20 do
    local chunk = pty:read()
    if chunk and #chunk > 0 then
        collected = collected .. chunk
        vt_lib.vterm_input_write(vt, chunk, #chunk)
        if collected:find("你好KOReader") then break end
    end
    os.execute("sleep 0.05")
end

vt_lib.vterm_screen_flush_damage(screen)
print("[TEST-HEADLESS] PTY raw output: " .. collected)
assert(collected:find("你好KOReader"), "Failed to receive Chinese output from shell")

print("[TEST-HEADLESS] 4. Inspecting rendered cell matrix...")
local cell = ffi.new("VTermScreenCell")
local pos = ffi.new("VTermPos")

-- 扫描前 3 行找到包含 "你好" 的单元格
local found_chinese = false
for r = 0, 3 do
    pos.row = r
    for c = 0, 78 do
        pos.col = c
        vt_lib.vterm_screen_get_cell(screen, pos, cell)
        -- 你 的 Unicode 是 0x4F60
        if cell.chars[0] == 0x4F60 and cell.width == 2 then
            found_chinese = true
            print(string.format("[TEST-HEADLESS] Found 你 at row %d col %d with width=2 (Double Width CJK Verified!)", r, c))
            break
        end
    end
    if found_chinese then break end
end

assert(found_chinese, "Double-width Chinese character 你 not found in terminal matrix")

print("[TEST-HEADLESS] 5. Cleaning up resources...")
pty:write("exit\n")
pty:close()
vt_lib.vterm_free(vt)

print("[TEST-HEADLESS] 6. Verifying _meta.lua integrity...")
local meta = dofile("/home/m/koreader/plugins/vterm.koplugin/_meta.lua")
assert(meta.name == "vterm", "Plugin name mismatch in _meta.lua")

print("\n========================================================")
print("  [SUCCESS] vterm.koplugin Phase 1-3 Headless Verification PASSED!")
print("========================================================")
