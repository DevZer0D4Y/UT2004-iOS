// libShimCarbon.dylib — stands in for Carbon.framework on iOS.
// Core.dylib uses the Carbon standard alert for fatal errors; MetalDrv's two
// macOS-only Metal device-observer calls are rebound here too (machotool
// rebind), because every module already links Carbon.
#import <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>

#define EXPORT __attribute__((visibility("default")))

typedef struct {
    char title[1024];
    char text[4096];
} ShimAlert;

static void cfstr(CFStringRef s, char *out, size_t n)
{
    out[0] = 0;
    if (s)
        CFStringGetCString(s, out, (CFIndex)n, kCFStringEncodingUTF8);
}

EXPORT int32_t CreateStandardAlert(int16_t alertType, CFStringRef error, CFStringRef explanation,
                                   const void *param, void **outAlert)
{
    (void)alertType;
    (void)param;
    ShimAlert *a = calloc(1, sizeof *a);
    cfstr(error, a->title, sizeof a->title);
    cfstr(explanation, a->text, sizeof a->text);
    if (outAlert)
        *outAlert = a;
    return 0;
}

EXPORT int32_t RunStandardAlert(void *inAlert, void *filterProc, int16_t *outItemHit)
{
    (void)filterProc;
    ShimAlert *a = inAlert;
    if (a) {
        fprintf(stderr, "[alert] %s: %s\n", a->title, a->text);
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, a->title[0] ? a->title : "UT2004", a->text, NULL);
        free(a);
    }
    if (outItemHit)
        *outItemHit = 1;
    return 0;
}

// macOS-only Metal device enumeration with hot-plug observer. iOS has one GPU.
// Own C names + asm labels: the macOS SDK declares these with other types.
EXPORT NSArray *shim_MTLCopyAllDevicesWithObserver(id *observer, void *handler)
    __asm__("_MTLCopyAllDevicesWithObserver");
NSArray *shim_MTLCopyAllDevicesWithObserver(id *observer, void *handler)
{
    (void)handler;
    if (observer)
        *observer = nil;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); // +1
    NSArray *all = dev ? [[NSArray alloc] initWithObjects:dev, nil] : [[NSArray alloc] init];
    [dev release];
    return all; // "Copy" rule: caller owns it
}

EXPORT void shim_MTLRemoveDeviceObserver(id observer) __asm__("_MTLRemoveDeviceObserver");
void shim_MTLRemoveDeviceObserver(id observer)
{
    (void)observer;
}
