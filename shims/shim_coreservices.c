// libShimCoreServices.dylib — Gestalt() for Core.dylib on iOS.
// Core only asks for 'ram ' (physical memory, bytes, 32-bit response).
#include <stdint.h>
#include <sys/sysctl.h>

#define EXPORT __attribute__((visibility("default")))
#define FOURCC(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))

EXPORT int16_t Gestalt(uint32_t selector, int32_t *response)
{
    if (!response)
        return -50; /* paramErr */
    if (selector == FOURCC('r', 'a', 'm', ' ')) {
        uint64_t mem = 0;
        size_t len = sizeof mem;
        sysctlbyname("hw.memsize", &mem, &len, NULL, 0);
        *response = mem > INT32_MAX ? INT32_MAX : (int32_t)mem;
        return 0;
    }
    return -5551; /* gestaltUndefSelectorErr */
}
