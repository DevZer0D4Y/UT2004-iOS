// Reads a little live engine state through Core/SDLDrv exports, and keeps the
// mouse mode right for touch input.
//
// UT2004 sets UPlayer::bShowWindowsMouse while any GUI menu is open. SDLDrv
// only drops mouse capture (absolute cursor) on a mouse-button release in a
// menu, and only with CaptureMouse=False; otherwise menus run on relative
// mouse deltas, which a touch screen cannot drive. host_mouse_mode_tick()
// releases capture whenever a menu is open and re-captures in gameplay, using
// SDLDrv's own USDLViewport::SetMouseCapture.
#include "host_common.h"

#include <SDL3/SDL_keyboard.h>
#include <SDL3/SDL_mouse.h>
#include <SDL3/SDL_video.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdint.h>

// UPlayer (Engine/Classes/Player.uc): bitfield byte at +0x78 (64-bit build):
// bit 0 bWindowsMouseAvailable, bit 1 bShowWindowsMouse. Verified with
// "getall Player bShowWindowsMouse" and SDLDrv's UpdateMouseGrabState.
#define PLAYER_MOUSE_FLAGS 0x78

typedef void *(*find_object_fn)(void *cls, void *outer, const wchar_t *name, int exact);
typedef void (*set_capture_fn)(void *viewport, int capture, int clip, int focus_only);

static find_object_fn g_find;
static set_capture_fn g_set_capture;
static void *g_viewport_class;
static void *g_viewport;

static bool have_window(void)
{
    int n = 0;
    SDL_Window **all = SDL_GetWindows(&n);
    SDL_free(all);
    return n > 0;
}

void *host_viewport(void)
{
    if (g_viewport)
        return g_viewport;
    // FName lookups crash before the engine is up; the game window comes later
    if (!have_window())
        return NULL;
    if (!g_find) {
        g_find = (find_object_fn)dlsym(RTLD_DEFAULT, "_ZN7UObject16StaticFindObjectEP6UClassPS_PKwi");
        g_set_capture = (set_capture_fn)dlsym(RTLD_DEFAULT, "_ZN12USDLViewport15SetMouseCaptureEiii");
        g_viewport_class = dlsym(RTLD_DEFAULT, "_ZN12USDLViewport18PrivateStaticClassE");
    }
    if (!g_find || !g_viewport_class)
        return NULL;
    g_viewport = g_find(g_viewport_class, (void *)-1 /* ANY_PACKAGE */, L"SDLViewport0", 0);
    if (g_viewport)
        host_log("[game] viewport %p", g_viewport);
    return g_viewport;
}

int host_mouse_flags(void)
{
    void *vp = host_viewport();
    return vp ? *((volatile uint8_t *)vp + PLAYER_MOUSE_FLAGS) : -1;
}

int host_menu_active(void)
{
    void *vp = host_viewport();
    if (!vp)
        return -1;
    return (*((volatile uint8_t *)vp + PLAYER_MOUSE_FLAGS) >> 1) & 1;
}

static int g_last_menu = -1;
static bool g_released; // we dropped capture for a menu

void host_mouse_mode_tick(void)
{
    int menu = host_menu_active();
    if (menu < 0 || !g_set_capture)
        return;
    host_crash_report_install();
    // keep System/UT2004.log on disk current (it is only written at exit otherwise)
    static unsigned ticks;
    if (++ticks % 20 == 0)
        host_flush_engine_log();
    // SDLDrv asserts that SDL_SetWindowMouseGrab succeeds; macOS refuses a grab
    // for a window without input focus (UIKit has no grab hook and never fails).
    SDL_Window *win = SDL_GetKeyboardFocus();
    if (win && (SDL_GetWindowFlags(win) & SDL_WINDOW_INPUT_FOCUS)) {
        bool cursor = SDL_CursorVisible();
        if (menu && !cursor) {
            g_set_capture(g_viewport, 0, 0, 0); // absolute pointer for the GUI
            g_released = true;
        } else if (!menu && g_released) {
            g_set_capture(g_viewport, 1, 1, 0); // back to relative look
            g_released = false;
        }
    }
    if (menu != g_last_menu) {
        host_log("[game] %s (flags %#x)", menu ? "menu" : "gameplay", host_mouse_flags());
        g_last_menu = menu;
    }
}

static dispatch_source_t g_timer;

void host_mouse_mode_start(void)
{
    if (g_timer)
        return;
    g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 100 * NSEC_PER_MSEC,
                              20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler_f(g_timer, (dispatch_function_t)host_mouse_mode_tick);
    dispatch_resume(g_timer);
}
