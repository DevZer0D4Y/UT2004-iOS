// UT2004 port additions to SDL3 (compiled into our libSDL3.0.dylib).
//
// SDLDrv reads mouse look with SDL_GetRelativeMouseState() and buttons with
// SDL_GetMouseState(), which SDL_PushEvent() does not update. These calls feed
// SDL's own input pipeline instead, exactly like a real mouse/keyboard would.
// Call them on the main (event) thread.
#pragma once
#include <SDL3/SDL_stdinc.h>
#include <SDL3/SDL_scancode.h>

#ifdef __cplusplus
extern "C" {
#endif

// Lets SDL_SetWindowRelativeMouseMode() succeed on touch-only devices (iOS has
// no relative mode without a GCMouse). Safe to call repeatedly.
extern SDL_DECLSPEC void SDLCALL SDL_UT_EnsureRelativeMouseMode(void);
// Calls SDL_UT_EnsureRelativeMouseMode() whenever SDLDrv is about to switch
// relative mode (hint SDL_MOUSE_EMULATE_WARP_WITH_RELATIVE). Call before the game starts.
extern SDL_DECLSPEC void SDLCALL SDL_UT_InstallRelativeModeFallback(void);

extern SDL_DECLSPEC void SDLCALL SDL_UT_MouseMotion(float dx, float dy);
extern SDL_DECLSPEC void SDLCALL SDL_UT_MouseMoveTo(float x, float y);
extern SDL_DECLSPEC void SDLCALL SDL_UT_MouseButton(Uint8 button, bool down);
extern SDL_DECLSPEC void SDLCALL SDL_UT_MouseWheel(float dy);
extern SDL_DECLSPEC void SDLCALL SDL_UT_Key(SDL_Scancode scancode, bool down);
extern SDL_DECLSPEC void SDLCALL SDL_UT_Text(const char *utf8);

// Render scale (UIKit): report window pixel sizes as points * scale and give
// SDL's Metal views that scale, instead of the screen's nativeScale. Inits the
// video subsystem if needed; call before the game creates its window.
extern SDL_DECLSPEC bool SDLCALL SDL_UT_SetPixelScale(float scale);

#ifdef __cplusplus
}
#endif
