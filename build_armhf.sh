#!/bin/bash
# Kobo/armhf 硬浮点 libvterm.so 单独构建 —— Kindle softfp 构建零改动。
# 产物: lib/armv7_hardfp/libvterm.so (不覆盖 lib/armv7_softfp/, 不进 Kindle 路径)。
# 用法(WSL/Debian): bash build_armhf.sh
# 日志: .build_armhf.log
set -u
REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"
LOG="$REPO/.build_armhf.log"
: > "$LOG"
exec > "$LOG" 2>&1

# 工具链选择: 硬浮点前缀优先; 没有就用软浮点前缀 + -mfloat-abi=hard 零安装路径,
# 成败由 readelf 的 Tag_ABI_VFP_args 验证, 不靠猜。
if command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then
    CROSS=arm-linux-gnueabihf-
elif command -v arm-linux-gnueabi-gcc >/dev/null 2>&1; then
    CROSS=arm-linux-gnueabi-
else
    echo "[!] 无 ARM 交叉编译器"; exit 1
fi
CC="${CROSS}gcc"
STRIP="${CROSS}strip"
echo "CC=$CC  version=$("$CC" -dumpversion)"

mkdir -p lib/armv7_hardfp
# vfpv3-d16 = armhf 基线 FPU(所有硬浮点 armv7 必有); 不用 neon —— 若 i.MX6 SoloLite
# 无 NEON, neon 代码会 SIGILL。d16 在任何硬浮点机上都对。
CFLAGS="-march=armv7-a -mtune=cortex-a9 -mfpu=vfpv3-d16 -mfloat-abi=hard -O2 -fPIC -std=c99 -Wall -D_GNU_SOURCE"
INCLUDES="-Isrc/libvterm/include -Isrc/libvterm/src"

"$CC" $CFLAGS $INCLUDES -shared \
    src/libvterm/src/encoding.c \
    src/libvterm/src/keyboard.c \
    src/libvterm/src/mouse.c \
    src/libvterm/src/parser.c \
    src/libvterm/src/pen.c \
    src/libvterm/src/screen.c \
    src/libvterm/src/state.c \
    src/libvterm/src/unicode.c \
    src/libvterm/src/vterm.c \
    src/vterm_bridge.c \
    -o lib/armv7_hardfp/libvterm.so || { echo "[!] 编译失败"; exit 1; }

"$STRIP" --strip-unneeded lib/armv7_hardfp/libvterm.so

echo "=== ELF header (Flags 必须含 hard-float ABI) ==="
readelf -h lib/armv7_hardfp/libvterm.so | grep -E "Machine|Flags"
echo "=== ARM attributes (必须 Tag_ABI_VFP_args: VFP register arguments) ==="
readelf -A lib/armv7_hardfp/libvterm.so | grep -E "Tag_ABI_VFP_args|Tag_FP_arch|Tag_CPU_name" || true
echo "=== glibc 符号版本要求 (须 <= 设备 glibc) ==="
readelf -V lib/armv7_hardfp/libvterm.so | grep -o "GLIBC_[0-9.]*" | sort -u || echo "(无版本化符号)"
echo "[+] DONE lib/armv7_hardfp/libvterm.so $(stat -c%s lib/armv7_hardfp/libvterm.so) bytes"
