local ok, gettext = pcall(require, "gettext")
local _ = ok and gettext or function(s) return s end

return {
    name = "vterm",
    version = "v1.3.1",
    fullname = _("VTerm 增强终端"),
    description = _("基于 libvterm 的增强终端模拟器，完整支持 Vim、中文双宽对齐与远程 SSH (PuTTY) 会话"),
}
