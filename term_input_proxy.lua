local InputText = require("ui/widget/inputtext")
local UIManager = require("ui/uimanager")

local TermInputProxy = InputText:extend{
    strike_callback = nil,
    enter_callback = nil,
    del_word_callback = nil,
}

-- 核心 1：拦截键盘输入字符 (包括单个字母、中文输入法词组、符号、回车)
function TermInputProxy:addChars(chars, skip_callback, skip_table_concat)
    if not chars or #chars == 0 then return end

    -- 拦截软键盘回车键 (Enter / Return 均产生 \n)
    if chars == "\n" then
        if self.enter_callback then
            self.enter_callback()
        elseif self.strike_callback then
            -- 明确发送换行符 \n 提交 Shell 命令执行
            self.strike_callback("\n")
        end
        return
    end

    -- 普通字符输入直接写入 PTY
    if self.strike_callback then
        self.strike_callback(chars)
        return
    end

    InputText.addChars(self, chars, skip_callback, skip_table_concat)
end

-- 核心 2：拦截退格键 (Backspace)
function TermInputProxy:delChar()
    if self.strike_callback then
        -- 终端标准退格码: 0x7F (DEL) 或 0x08 (BS)
        self.strike_callback("\x7f")
        return
    end
    InputText.delChar(self)
end

-- 核心 3：拦截删除词 (Ctrl+W)
function TermInputProxy:delWord(left_to_cursor)
    if self.del_word_callback then
        self.del_word_callback()
        return
    end
    if self.strike_callback then
        self.strike_callback("\023") -- Ctrl+W
        return
    end
    InputText.delWord(self, left_to_cursor)
end

-- 核心 4：拦截方向键与光标移动，转化为 ANSI 序列发送给终端
function TermInputProxy:leftChar()
    if self.strike_callback then
        self.strike_callback("\27[D")
        return
    end
    InputText.leftChar(self)
end

function TermInputProxy:rightChar()
    if self.strike_callback then
        self.strike_callback("\27[C")
        return
    end
    InputText.rightChar(self)
end

function TermInputProxy:upLine()
    if self.strike_callback then
        self.strike_callback("\27[A")
        return
    end
    InputText.upLine(self)
end

function TermInputProxy:downLine()
    if self.strike_callback then
        self.strike_callback("\27[B")
        return
    end
    InputText.downLine(self)
end

function TermInputProxy:goToStartOfLine()
    if self.strike_callback then
        self.strike_callback("\27[H")
        return
    end
    InputText.goToStartOfLine(self)
end

function TermInputProxy:goToEndOfLine()
    if self.strike_callback then
        self.strike_callback("\27[F")
        return
    end
    InputText.goToEndOfLine(self)
end

return TermInputProxy
