local ffi = require("ffi")

ffi.cdef[[
typedef struct VTerm VTerm;
typedef struct VTermScreen VTermScreen;
typedef struct VTermState VTermState;

typedef struct {
    int row;
    int col;
} VTermPos;

typedef struct {
    int start_row;
    int end_row;
    int start_col;
    int end_col;
} VTermRect;

typedef union {
    uint8_t type;
    struct { uint8_t type, red, green, blue; } rgb;
    struct { uint8_t type, idx; } indexed;
} VTermColor;

typedef struct {
    unsigned int bold      : 1;
    unsigned int underline : 2;
    unsigned int italic    : 1;
    unsigned int blink     : 1;
    unsigned int reverse   : 1;
    unsigned int conceal   : 1;
    unsigned int strike    : 1;
    unsigned int font      : 4;
    unsigned int dwl       : 1;
    unsigned int dhl       : 2;
    unsigned int small     : 1;
    unsigned int baseline  : 2;
} VTermScreenCellAttrs;

typedef struct {
    uint32_t chars[6];
    char     width;
    VTermScreenCellAttrs attrs;
    VTermColor fg, bg;
} VTermScreenCell;

typedef int (*damage_flat_fn)(int start_row, int end_row, int start_col, int end_col, void *user);
typedef int (*movecursor_flat_fn)(int row, int col, int old_row, int old_col, int visible, void *user);
typedef int (*bell_fn)(void *user);
typedef int (*moverect_cb)(VTermRect dest, VTermRect src, void *user);
typedef int (*erase_cb)(VTermRect rect, int selective, void *user);
typedef void (*copycell_cb)(VTermPos dest, VTermPos src, void *user);
typedef int (*sb_pushline4_cb)(int cols, const VTermScreenCell *cells, int continuation, void *user);
typedef int (*flat_pushline_fn)(int cols, const VTermScreenCell *cells, int continuation, void *user);

typedef struct {
    unsigned int    doublewidth:1;
    unsigned int    doubleheight:2;
    unsigned int    continuation:1;
} VTermLineInfo;

typedef struct {
    damage_flat_fn damage;
    movecursor_flat_fn movecursor;
    bell_fn bell;
    void *user;
} VTermBridgeCallbacks;

VTerm *vterm_new(int rows, int cols);
void vterm_free(VTerm *vt);
void vterm_set_utf8(VTerm *vt, int is_utf8);
void vterm_set_size(VTerm *vt, int rows, int cols);
void vterm_get_size(const VTerm *vt, int *rowsp, int *colsp);
size_t vterm_input_write(VTerm *vt, const char *bytes, size_t len);

VTermScreen *vterm_obtain_screen(VTerm *vt);
void vterm_screen_enable_altscreen(VTermScreen *screen, int enable);
void vterm_screen_reset(VTermScreen *screen, int hard);
void vterm_screen_flush_damage(VTermScreen *screen);
int vterm_screen_get_cell(const VTermScreen *screen, VTermPos pos, VTermScreenCell *cell);
int vterm_screen_is_eol(const VTermScreen *screen, VTermPos pos);

VTermState *vterm_obtain_state(VTerm *vt);
void vterm_state_get_cursorpos(const VTermState *state, VTermPos *pos);
const VTermLineInfo *vterm_state_get_lineinfo(const VTermState *state, int row);

void vterm_scroll_rect(VTermRect rect, int downward, int rightward,
                       moverect_cb moverect, erase_cb eraserect, void *user);
void vterm_copy_cells(VTermRect dest, VTermRect src, copycell_cb copycell, void *user);

/* 本地滚动钩子(源码 src/vterm_bridge.c):
   pushline4 = 官方"行滚出主屏"回调, 带 continuation 位。
   会重设整张 callbacks 表, 内部保留 set_callbacks 挂的 damage/movecursor。 */
void vterm_bridge_set_scrollhooks(VTermScreen *screen, void *unused_moverect,
                                  flat_pushline_fn pushline4, void *user);

void vterm_bridge_set_callbacks(VTermScreen *screen, VTermBridgeCallbacks *bridge_cb);
]]

local VTermFFI = {}

function VTermFFI.load(plugin_dir)
    local so_path
    if plugin_dir then
        local test_x86 = plugin_dir .. "/lib/x86_64/libvterm.so"
        local test_arm = plugin_dir .. "/lib/armv7_softfp/libvterm.so"
        local f = io.open(test_x86, "r")
        if f then
            f:close()
            so_path = test_x86
        else
            so_path = test_arm
        end
    else
        so_path = "./lib/x86_64/libvterm.so"
    end

    local ok, lib = pcall(ffi.load, so_path)
    if not ok then
        lib = ffi.load("./lib/x86_64/libvterm.so")
    end
    return lib
end

function VTermFFI.newTerminal(lib, rows, cols)
    local vt = lib.vterm_new(rows, cols)
    lib.vterm_set_utf8(vt, 1)
    local screen = lib.vterm_obtain_screen(vt)
    lib.vterm_screen_reset(screen, 1)
    lib.vterm_screen_enable_altscreen(screen, 1)
    return vt, screen
end

return VTermFFI
