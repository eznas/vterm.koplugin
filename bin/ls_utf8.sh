# busybox ls 显示 UTF-8 文件名为 '?'(Kindle busybox 1.28 编译未开 Unicode 支持)。
# 用 find 原样输出字节替代; find 对输出不做字符集转换。
# 用法约定(终端场景足够): ls [路径...] —— 标志参数尽量少用, 常见 -l/-a/-d 已适配。
ls() {
    local paths="" flags=""
    local a
    for a in "$@"; do
        case "$a" in
            -*) flags="$flags $a" ;;
            *)  paths="$paths $a" ;;
        esac
    done
    if [ -z "$paths" ]; then
        paths=" ."
    fi
    local p
    for p in $paths; do
        if [ -d "$p" ]; then
            if [ -n "$flags" ]; then
                # 带标志(-l 等)仍走原 ls(元数据不含文件名字符集问题较少, 但长名仍会 ?)
                busybox ls $flags "$p"
            else
                busybox find "$p" -maxdepth 1 ! -path "$p" | busybox sed 's|^.*/||' | busybox sort
            fi
        else
            printf '%s\n' "$p"
        fi
    done
}
