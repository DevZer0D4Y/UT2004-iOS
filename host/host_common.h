#pragma once

// Both iOS and the macOS test build use the same flat bundle:
//   UT2004.app/UT2004                  host executable
//   UT2004.app/Frameworks/*.dylib      engine modules, SDL3, OpenAL, shims
//   UT2004.app/System/ ...             game system files from the patch
#define HOST_GAME_DYLIB_SUBPATH "Frameworks/UT2004Main.dylib"

#ifdef __cplusplus
extern "C" {
#endif

void host_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void host_open_log(const char *path);

// Load UT2004Main.dylib (OldUnreal's launcher) and run its main() on a big
// stack on the current thread.
int host_run_game(int argc, char **argv, char **envp);

// Optional test hook: linked in only when a build adds it (DEVTOOLS in build.sh).
void host_autoinput_start(void) __attribute__((weak));

// Objective-C/Metal compatibility for MetalDrv (objc_compat.m).
void ut_objc_compat_install(void);

// Live engine state (game_state.c). Main thread only.
void *host_viewport(void);         // USDLViewport* or NULL before the engine is up
int host_menu_active(void);        // 1 menu open, 0 gameplay, -1 unknown yet
int host_mouse_flags(void);        // raw UPlayer mouse bits (+0x78), -1 unknown
void host_mouse_mode_tick(void);   // match mouse capture to menu/gameplay
void host_mouse_mode_start(void);  // run host_mouse_mode_tick every 100 ms

// In-process thread stack dumps (env UT2004_STACKDUMP), see stackdump.cpp.
void host_stackdump_start(void);
// Crash report to the host log, chained in front of the engine's handler, and
// a flush of the engine's buffered log (System/UT2004.log). Main thread.
void host_crash_report_install(void);
void host_flush_engine_log(void);

#ifdef __cplusplus
}
#endif
