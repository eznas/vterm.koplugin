package.path = "/home/m/koreader/plugins/vterm.koplugin/?.lua;" .. package.path
local ffi = require("ffi")
local VTermFFI = require("vterm_ffi")

local plugin_dir = "/home/m/koreader/plugins/vterm.koplugin"
local vt_lib = VTermFFI.load(plugin_dir)
assert(vt_lib, "Failed to load libvterm.so")

print("[TEST] 1. Creating vterm instance via VTermFFI.newTerminal (24, 80)...")
local vt, screen = VTermFFI.newTerminal(vt_lib, 24, 80)

print("[TEST] 2. Writing English + Chinese text with ANSI escape...")
local test_input = "Hello \27[31mRed\27[0m \27[1m世界\27[0m!\r\n"
vt_lib.vterm_input_write(vt, test_input, #test_input)
vt_lib.vterm_screen_flush_damage(screen)

print("[TEST] 3. Verifying cell contents in row 0...")
local cell = ffi.new("VTermScreenCell")
local pos = ffi.new("VTermPos")
pos.row = 0

local row_chars = {}
for col = 0, 16 do
    pos.col = col
    vt_lib.vterm_screen_get_cell(screen, pos, cell)
    local codepoint = cell.chars[0]
    local w = tonumber(cell.width)
    table.insert(row_chars, string.format("[%d: U+%04X w=%d]", col, codepoint, w))
end

print(table.concat(row_chars, " "))

-- 验证汉字 "世" (U+4E16) 的 width 必须是 2
pos.col = 10 -- "Hello Red " 是 10 个字符 (0..9)
vt_lib.vterm_screen_get_cell(screen, pos, cell)
print(string.format("Character at col 10: codepoint=0x%X, width=%d", cell.chars[0], cell.width))
assert(cell.chars[0] == 0x4E16, "Expected 世 (U+4E16) at col 10")
assert(cell.width == 2, "Expected width=2 for Chinese character 世")

-- 验证汉字 "界" (U+754C) 在 col 12
pos.col = 12
vt_lib.vterm_screen_get_cell(screen, pos, cell)
print(string.format("Character at col 12: codepoint=0x%X, width=%d", cell.chars[0], cell.width))
assert(cell.chars[0] == 0x754C, "Expected 界 (U+754C) at col 12")
assert(cell.width == 2, "Expected width=2 for Chinese character 界")

print("[TEST] 4. Testing Cursor Position & Alternate Screen (Vim behavior)...")
-- 模拟进入 Vim: \e[?1049h (进入备用屏幕) + \e[H (光标置顶)
local enter_vim = "\27[?1049h\27[H\27[2J~   Vim Test File\r\n~"
vt_lib.vterm_input_write(vt, enter_vim, #enter_vim)
vt_lib.vterm_screen_flush_damage(screen)

pos.row = 0
pos.col = 0
vt_lib.vterm_screen_get_cell(screen, pos, cell)
assert(cell.chars[0] == string.byte("~"), "Row 0 should start with ~")

-- 模拟退出 Vim: \e[?1049l
local exit_vim = "\27[?1049l"
vt_lib.vterm_input_write(vt, exit_vim, #exit_vim)
vt_lib.vterm_screen_flush_damage(screen)

-- 退出后原内容应恢复
pos.row = 0
pos.col = 0
vt_lib.vterm_screen_get_cell(screen, pos, cell)
assert(cell.chars[0] == string.byte("H"), "Row 0 should be restored to H after exiting Vim")

vt_lib.vterm_free(vt)
print("[SUCCESS] All libvterm FFI tests PASSED! Vim alternate buffer and Chinese double-width verified.")
