local ok, json = pcall(require, "json")
if not ok then
    ok, json = pcall(require, "cjson")
end

local JSON_FALLBACK = {
    encode = function(tbl)
        local parts = {}
        local is_array = (#tbl > 0)
        if is_array then
            for _, v in ipairs(tbl) do
                if type(v) == "table" then
                    table.insert(parts, JSON_FALLBACK.encode(v))
                elseif type(v) == "string" then
                    table.insert(parts, string.format("%q", v))
                else
                    table.insert(parts, tostring(v))
                end
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(tbl) do
                local val_str
                if type(v) == "table" then
                    val_str = JSON_FALLBACK.encode(v)
                elseif type(v) == "string" then
                    val_str = string.format("%q", v)
                else
                    val_str = tostring(v)
                end
                table.insert(parts, string.format("%q:%s", tostring(k), val_str))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end,
    decode = function(str)
        local lua_str = str:gsub("%[", "{"):gsub("%]", "}"):gsub('"(.-)"%s*:', '["%1"]=')
        local func = loadstring("return " .. lua_str)
        if func then
            return func()
        end
        return {}
    end
}

local JSON = (ok and json) and json or JSON_FALLBACK

local SessionMgr = {}
SessionMgr.__index = SessionMgr

function SessionMgr.new(config_path, plugin_path)
    local self = setmetatable({}, SessionMgr)
    self.config_path = config_path or "/mnt/us/koreader/plugins/vterm.koplugin/sessions.json"
    self.plugin_path = plugin_path
    self.sessions = {}
    self:load()
    return self
end

function SessionMgr:load()
    local f = io.open(self.config_path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local ok_dec, data = pcall(JSON.decode, content)
        if ok_dec and type(data) == "table" then
            self.sessions = data
            return
        end
    end
    self.sessions = {
        {
            name = "Local Shell",
            type = "local",
            cmd = "/bin/sh",
        },
    }
end

function SessionMgr:save()
    local f = io.open(self.config_path, "w")
    if f then
        local ok_enc, content = pcall(JSON.encode, self.sessions)
        if ok_enc then
            f:write(content)
        end
        f:close()
    end
end

function SessionMgr:list()
    return self.sessions
end

function SessionMgr:add(session)
    table.insert(self.sessions, session)
    self:save()
end

-- 覆盖指定索引的会话(编辑保存)
function SessionMgr:update(index, session)
    if self.sessions[index] then
        self.sessions[index] = session
        self:save()
    end
end

function SessionMgr:delete(index)
    if self.sessions[index] then
        table.remove(self.sessions, index)
        self:save()
    end
end

-- 智能探测可用 SSH / Dropbear 二进制客户端
function SessionMgr:getSshBinary()
    local candidates = {
        "/mnt/us/koreader/plugins/vterm.koplugin/bin/dbclient",
        "/mnt/us/koreader/dbclient",
        "/usr/bin/dbclient",
        "/usr/bin/ssh",
        "/bin/ssh",
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return "ssh"
end

function SessionMgr:buildLaunchCommand(session)
    if session.type == "local" then
        local cmd = session.cmd or os.getenv("SHELL") or "/bin/sh"
        local args = session.args
        -- 插件自带 Unicode busybox: 本地默认 shell 升级到 `busybox ash -i`。
        -- 设备 /bin/bash 是老 busybox 符号链接, lineedit 无 Unicode → CJK
        -- 回显 ?、退格按字节; 插件重编版(CONFIG_LAST_SUPPORTED_WCHAR=65535)
        -- 行编辑/历史/ls 原生正确(qemu 实测)。仅 ARM 真机升级: 模拟器(x86)
        -- 带的是 ARM 二进制不可执行。显式配置了非默认 shell 则尊重用户。
        if not args and (cmd == "/bin/bash" or cmd == "/bin/sh" or cmd == "/bin/ash")
            and jit and jit.arch and jit.arch:lower():find("arm", 1, true)
            and self.plugin_path then
            local bb = self.plugin_path .. "/bin/busybox"
            local f = io.open(bb, "rb")
            if f then
                f:close()
                return bb, { "ash", "-i" }
            end
        end
        -- bash 会读用户 rc 覆盖 vterm 注入的 PS1([V] 行标记丢失 → 影子行合成
        -- 与回显翻译整体休眠)。本地会话统一 --norc 保证 PS1 生效。
        -- 设备上 $SHELL 为空 → /bin/sh(busybox ash 不读 rc), 本分支不触发。
        if not args and cmd:match("bash$") then
            args = { "--norc", "--noprofile", "-i" }
        end
        return cmd, args
    end

    local bin = self:getSshBinary()
    local args = {}

    local port = tostring(session.port or "22")
    -- 两种 SSH 后端共享的 -p <port> / -i <key> 参数(原两分支逐字重复)
    table.insert(args, "-p")
    table.insert(args, port)
    if session.key_path and #session.key_path > 0 then
        table.insert(args, "-i")
        table.insert(args, session.key_path)
    end
    if not bin:find("dbclient") then
        table.insert(args, "-o")
        -- accept-new: 首连自动记录指纹, 指纹变更仍拒绝(MITM 防护保留);
        -- known_hosts 持久化到插件目录, 避免静默信任任意指纹
        table.insert(args, "StrictHostKeyChecking=accept-new")
        local dir = self.config_path:match("^(.*/)")
        if dir then
            table.insert(args, "-o")
            table.insert(args, "UserKnownHostsFile=" .. dir .. "known_hosts")
        end
    end

    local target = session.host
    if session.user and #session.user > 0 then
        target = session.user .. "@" .. session.host
    end
    table.insert(args, target)

    return bin, args
end

return SessionMgr
