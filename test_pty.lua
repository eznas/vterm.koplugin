package.path = "/home/m/koreader/plugins/vterm.koplugin/?.lua;" .. package.path
local PTY = require("pty")

print("[TEST] 1. Creating PTY and spawning subshell (sh)...")
local pty = PTY.new()
local ok, pid = pty:spawn("/bin/sh", nil, 24, 80)
assert(ok, "Failed to spawn PTY: " .. tostring(pid))

print("[TEST] 2. Sending command: echo \"你好世界 xterm-256color\"...")
pty:write("echo \"你好世界 xterm-256color\"\n")

local out = ""
for i = 1, 30 do
    local chunk = pty:read()
    if chunk and #chunk > 0 then
        out = out .. chunk
        if out:find("xterm%-256color") then break end
    end
    os.execute("sleep 0.05")
end

print("[TEST] PTY Output captured (" .. #out .. " bytes):")
print(out)
assert(out:find("xterm%-256color"), "Expected TERM=xterm-256color")

pty:write("exit\n")
pty:close()
print("[SUCCESS] PTY test PASSED!")
