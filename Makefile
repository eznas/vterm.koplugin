CC ?= gcc
CFLAGS ?= -O2 -fPIC -std=c99 -Wall
INCLUDES = -Isrc/libvterm/include -Isrc/libvterm/src

SRCS = src/libvterm/src/encoding.c        src/libvterm/src/keyboard.c        src/libvterm/src/mouse.c        src/libvterm/src/parser.c        src/libvterm/src/pen.c        src/libvterm/src/screen.c        src/libvterm/src/state.c        src/libvterm/src/unicode.c        src/libvterm/src/vterm.c        src/vterm_bridge.c

.PHONY: all x86 arm test clean

all: x86

x86:
	@mkdir -p lib/x86_64
	   -shared  -o lib/x86_64/libvterm.so
	@strip --strip-unneeded lib/x86_64/libvterm.so
	@echo "[+] Built lib/x86_64/libvterm.so"

arm:
	./build_arm.sh

test: x86
	@echo "=== Running VTerm FFI Test ==="
	cd ../../koreader-emulator-x86_64-linux-gnu-debug/koreader && ./luajit /home/m/koreader/plugins/vterm.koplugin/test_vterm_ffi.lua
	@echo "=== Running VTerm Headless Integration Test ==="
	cd ../../koreader-emulator-x86_64-linux-gnu-debug/koreader && ./luajit /home/m/koreader/plugins/vterm.koplugin/test_vterm_headless.lua

clean:
	rm -rf lib/x86_64/libvterm.so test_debug test_init test_init_screen test_c
