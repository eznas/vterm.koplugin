#!/bin/bash
set -euo pipefail

# 默认使用 arm-linux-gnueabi 或官方 NiLuJe toolchain
CROSS_PREFIX="arm-linux-gnueabi-"
CC="gcc"
STRIP="strip"

echo "=== 编译 Kindle/ARM 架构 libvterm.so ==="
echo "编译器: "

if ! which "" >/dev/null 2>&1; then
    echo "[!] 未在当前系统找到 ，请安装交叉编译器:"
    echo "    sudo apt-get install -y gcc-arm-linux-gnueabi"
    echo "    或者设置 CROSS_COMPILE=/path/to/x-tools/arm-kindlepw2-linux-gnueabi/bin/arm-kindlepw2-linux-gnueabi-"
    exit 1
fi

mkdir -p lib/armv7_softfp

CFLAGS="-march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=softfp -O2 -fPIC -std=c99 -Wall -D_GNU_SOURCE"
INCLUDES="-Isrc/libvterm/include -Isrc/libvterm/src"

   -shared     src/libvterm/src/encoding.c     src/libvterm/src/keyboard.c     src/libvterm/src/mouse.c     src/libvterm/src/parser.c     src/libvterm/src/pen.c     src/libvterm/src/screen.c     src/libvterm/src/state.c     src/libvterm/src/unicode.c     src/libvterm/src/vterm.c     src/vterm_bridge.c     -o lib/armv7_softfp/libvterm.so

 --strip-unneeded lib/armv7_softfp/libvterm.so

echo "[+] 编译成功: lib/armv7_softfp/libvterm.so"
file lib/armv7_softfp/libvterm.so
