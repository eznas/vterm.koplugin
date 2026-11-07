#include <vterm.h>
#include <stdlib.h>
#include <stdbool.h>

typedef int (*damage_flat_fn)(int start_row, int end_row, int start_col, int end_col, void *user);
typedef int (*movecursor_flat_fn)(int row, int col, int old_row, int old_col, int visible, void *user);
typedef int (*flat_pushline_fn)(int cols, const VTermScreenCell *cells, int continuation, void *user);

typedef struct {
    damage_flat_fn damage;
    movecursor_flat_fn movecursor;
    int (*bell)(void *user);
    void *user;
} VTermBridgeCallbacks;

/* set_callbacks 保存的 damage/movecursor/bell 源, 供滚动钩子复用 */
static VTermBridgeCallbacks g_base;
static bool g_base_set = false;
static flat_pushline_fn g_pushline4 = NULL;
static void *g_scroll_user = NULL;

static int bridge_damage(VTermRect rect, void *user) {
    VTermBridgeCallbacks *cb = (VTermBridgeCallbacks *)user;
    if (cb && cb->damage) {
        return cb->damage(rect.start_row, rect.end_row, rect.start_col, rect.end_col, cb->user);
    }
    return 0;
}

static int bridge_movecursor(VTermPos pos, VTermPos oldpos, int visible, void *user) {
    VTermBridgeCallbacks *cb = (VTermBridgeCallbacks *)user;
    if (cb && cb->movecursor) {
        return cb->movecursor(pos.row, pos.col, oldpos.row, oldpos.col, visible, cb->user);
    }
    return 0;
}

static int bridge_bell(void *user) {
    VTermBridgeCallbacks *cb = (VTermBridgeCallbacks *)user;
    if (cb && cb->bell) {
        return cb->bell(cb->user);
    }
    return 0;
}

/* 滚动钩子版本的回调: 固定从 g_base 取原回调 */
static int bridge_damage_scroll(VTermRect rect, void *user) {
    return bridge_damage(rect, &g_base);
}

static int bridge_movecursor_scroll(VTermPos pos, VTermPos oldpos, int visible, void *user) {
    return bridge_movecursor(pos, oldpos, visible, &g_base);
}

static int bridge_bell_scroll(void *user) {
    return bridge_bell(&g_base);
}

static int bridge_pushline4(int cols, const VTermScreenCell *cells, bool continuation, void *user) {
    if (g_pushline4)
        return g_pushline4(cols, cells, continuation ? 1 : 0, g_scroll_user);
    return 0;
}

void vterm_bridge_set_callbacks(VTermScreen *screen, VTermBridgeCallbacks *bridge_cb) {
    static VTermScreenCallbacks cbs;
    g_base = *bridge_cb;
    g_base_set = true;
    cbs.damage = bridge_damage;
    cbs.moverect = NULL;
    cbs.movecursor = bridge_movecursor;
    cbs.settermprop = NULL;
    cbs.bell = bridge_bell;
    cbs.resize = NULL;
    cbs.sb_pushline = NULL;
    cbs.sb_popline = NULL;
    cbs.sb_clear = NULL;
    cbs.sb_pushline4 = NULL;
    vterm_screen_set_callbacks(screen, &cbs, bridge_cb);
}

/* 滚动钩子: pushline4 在"行被滚出主屏"时触发, 带 continuation 位。
   libvterm 只保留一张 VTermScreenCallbacks, 所以这里要把 damage/movecursor
   一并挂回(set_callbacks 存下的), 否则会丢掉刷屏回调。
   unused_moverect 仅为接口占位: premove 视角拿到的是"被覆盖的旧内容", 不接。 */
void vterm_bridge_set_scrollhooks(VTermScreen *screen, void *unused_moverect,
                                  flat_pushline_fn pushline4, void *user) {
    static VTermScreenCallbacks cbs;
    (void)unused_moverect;
    g_pushline4 = pushline4;
    g_scroll_user = user;
    cbs.damage = (g_base_set && g_base.damage) ? bridge_damage_scroll : NULL;
    cbs.moverect = NULL;
    cbs.movecursor = (g_base_set && g_base.movecursor) ? bridge_movecursor_scroll : NULL;
    cbs.settermprop = NULL;
    cbs.bell = (g_base_set && g_base.bell) ? bridge_bell_scroll : NULL;
    cbs.resize = NULL;
    cbs.sb_pushline = NULL;
    cbs.sb_popline = NULL;
    cbs.sb_clear = NULL;
    cbs.sb_pushline4 = pushline4 ? bridge_pushline4 : NULL;
    if (pushline4)
        vterm_screen_callbacks_has_pushline4(screen);
    vterm_screen_set_callbacks(screen, &cbs, NULL);
}
