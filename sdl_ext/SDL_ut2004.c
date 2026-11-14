// UT2004 port additions to SDL3, built together with SDL's static library
// (tools/build_deps.sh) so they can use SDL's internal input functions.
#include "SDL_internal.h"
#include "events/SDL_keyboard_c.h"
#include "events/SDL_mouse_c.h"

#include "SDL_ut2004.h"

#define UT_MOUSE_ID SDL_DEFAULT_MOUSE_ID
#define UT_KEYBOARD_ID SDL_DEFAULT_KEYBOARD_ID

static bool UT_SetRelativeMouseMode(bool enabled)
{
    (void)enabled; // touch input: relative motion is synthesized, nothing to capture
    return true;
}

static SDL_Window *ut_window(void)
{
    SDL_Window *w = SDL_GetKeyboardFocus();
    if (!w)
        w = SDL_GetMouseFocus();
    if (!w) {
        int n = 0;
        SDL_Window **all = SDL_GetWindows(&n);
        if (all && n > 0)
            w = all[0];
        SDL_free(all);
    }
    return w;
}

void SDL_UT_EnsureRelativeMouseMode(void)
{
    SDL_Mouse *mouse = SDL_GetMouse();
    if (mouse && !mouse->SetRelativeMouseMode)
        mouse->SetRelativeMouseMode = UT_SetRelativeMouseMode;
}

// SDLDrv sets this hint right before SDL_SetWindowRelativeMouseMode() and
// asserts that the call succeeds; the hook must exist by then, which is
// during engine init, before the host gets the main thread back.
static void SDLCALL UT_RelativeHintCallback(void *userdata, const char *name, const char *old_value,
                                            const char *new_value)
{
    (void)userdata;
    (void)name;
    (void)old_value;
    (void)new_value;
    SDL_UT_EnsureRelativeMouseMode();
}

void SDL_UT_InstallRelativeModeFallback(void)
{
    SDL_AddHintCallback("SDL_MOUSE_EMULATE_WARP_WITH_RELATIVE", UT_RelativeHintCallback, NULL);
}

void SDL_UT_MouseMotion(float dx, float dy)
{
    SDL_SendMouseMotion(0, ut_window(), UT_MOUSE_ID, true, dx, dy);
}

void SDL_UT_MouseMoveTo(float x, float y)
{
    SDL_SendMouseMotion(0, ut_window(), UT_MOUSE_ID, false, x, y);
}

void SDL_UT_MouseButton(Uint8 button, bool down)
{
    SDL_SendMouseButton(0, ut_window(), UT_MOUSE_ID, button, down);
}

void SDL_UT_MouseWheel(float dy)
{
    SDL_SendMouseWheel(0, ut_window(), UT_MOUSE_ID, 0.0f, dy, SDL_MOUSEWHEEL_NORMAL);
}

void SDL_UT_Key(SDL_Scancode scancode, bool down)
{
    SDL_SendKeyboardKey(0, UT_KEYBOARD_ID, 0, scancode, down);
}

void SDL_UT_Text(const char *utf8)
{
    SDL_SendKeyboardText(utf8);
}

// ---- render scale -----------------------------------------------------------
// SDLDrv sizes its viewport from SDL_GetWindowSizeInPixels() (on UIKit: view
// points x screen nativeScale) while MetalDrv sizes the drawable from the
// game's configured resolution. To render below native resolution both must
// agree, so report window pixels and set the Metal view's scale with one
// factor. UIKit then scales the drawable up to the screen.
#include "video/SDL_sysvideo.h"
#include <objc/message.h>
#include <objc/runtime.h>

static float ut_pixel_scale;
static void (*ut_orig_size_in_pixels)(SDL_VideoDevice *, SDL_Window *, int *, int *);
static SDL_MetalView (*ut_orig_metal_create)(SDL_VideoDevice *, SDL_Window *);

static void UT_GetWindowSizeInPixels(SDL_VideoDevice *_this, SDL_Window *window, int *w, int *h)
{
    ut_orig_size_in_pixels(_this, window, w, h);
    if (ut_pixel_scale > 0.0f && (window->flags & SDL_WINDOW_HIGH_PIXEL_DENSITY)) {
        *w = (int)(window->w * ut_pixel_scale);
        *h = (int)(window->h * ut_pixel_scale);
    }
}

static SDL_MetalView UT_Metal_CreateView(SDL_VideoDevice *_this, SDL_Window *window)
{
    SDL_MetalView view = ut_orig_metal_create(_this, window);
    if (view && ut_pixel_scale > 0.0f && (window->flags & SDL_WINDOW_HIGH_PIXEL_DENSITY)) {
        // SDL_uikitmetalview sizes its layer's drawable from contentScaleFactor
        ((void (*)(id, SEL, double))objc_msgSend)((id)view, sel_registerName("setContentScaleFactor:"),
                                                  (double)ut_pixel_scale);
    }
    return view;
}

bool SDL_UT_SetPixelScale(float scale)
{
    if (!SDL_WasInit(SDL_INIT_VIDEO) && !SDL_InitSubSystem(SDL_INIT_VIDEO))
        return false;
    SDL_VideoDevice *dev = SDL_GetVideoDevice();
    if (!dev || !dev->GetWindowSizeInPixels)
        return SDL_SetError("no video device");
    if (!ut_orig_size_in_pixels) {
        ut_orig_size_in_pixels = dev->GetWindowSizeInPixels;
        dev->GetWindowSizeInPixels = UT_GetWindowSizeInPixels;
        if (dev->Metal_CreateView) {
            ut_orig_metal_create = dev->Metal_CreateView;
            dev->Metal_CreateView = UT_Metal_CreateView;
        }
    }
    ut_pixel_scale = scale;
    return true;
}
