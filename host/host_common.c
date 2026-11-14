// Shared launcher logic: load OldUnreal's launcher (converted to
// UT2004Main.dylib) and run its main() on a large stack.
#include "host_common.h"

#include <SDL3/SDL_ut2004.h>

#include <dlfcn.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define GAME_STACK_SIZE (256u << 20) /* reserved, not committed */
#define GUARD_SIZE (64u << 10)

typedef int (*game_main_fn)(int, char **, char **);
extern int ut_call_on_stack(void *stack_top, game_main_fn fn, int argc, char **argv, char **envp);

static FILE *g_log;

void host_log(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    if (g_log) {
        va_start(ap, fmt);
        vfprintf(g_log, fmt, ap);
        va_end(ap);
        fputc('\n', g_log);
        fflush(g_log);
    }
}

void host_open_log(const char *path)
{
    g_log = fopen(path, "w");
}

static void exe_dir(char *out, size_t n)
{
    uint32_t size = (uint32_t)n;
    if (_NSGetExecutablePath(out, &size) != 0) {
        out[0] = 0;
        return;
    }
    char *slash = strrchr(out, '/');
    if (slash)
        *slash = 0;
}

int host_run_game(int argc, char **argv, char **envp)
{
    char dir[1024], path[1200];
    exe_dir(dir, sizeof dir);
    snprintf(path, sizeof path, "%s/%s", dir, HOST_GAME_DYLIB_SUBPATH);

    host_log("[host] loading %s", path);
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        host_log("[host] dlopen failed: %s", dlerror());
        return 1;
    }
    game_main_fn game_main = (game_main_fn)dlsym(h, "main");
    if (!game_main) {
        host_log("[host] no main in %s: %s", path, dlerror());
        return 1;
    }

    size_t total = GAME_STACK_SIZE + GUARD_SIZE;
    char *stack = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (stack == MAP_FAILED) {
        host_log("[host] stack mmap failed: %s", strerror(errno));
        return 1;
    }
    mprotect(stack, GUARD_SIZE, PROT_NONE); /* stack grows down: guard at the bottom */
    host_log("[host] game main %p, stack %p-%p", (void *)game_main, (void *)(stack + GUARD_SIZE),
             (void *)(stack + total));
    SDL_UT_InstallRelativeModeFallback(); // touch-only iOS has no relative mouse mode
    host_mouse_mode_start();
    if (host_autoinput_start)
        host_autoinput_start();
    host_stackdump_start();
    int rc = ut_call_on_stack(stack + total, game_main, argc, argv, envp);
    host_log("[host] game main returned %d", rc);
    return rc;
}
