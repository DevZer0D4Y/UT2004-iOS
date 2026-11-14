// libShimIOKit.dylib — the IOKit calls SDLDrv makes on macOS (HID manager
// for raw mouse input, mouse acceleration). iOS has no such devices: return
// empty CF objects (SDLDrv calls CFSetGetCount on the device set and
// CFRelease on the manager) and "unsupported" for everything else.
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>

#define EXPORT __attribute__((visibility("default")))
#define kIOReturnUnsupported ((int)0xe00002c7)

EXPORT const mach_port_t kIOMainPortDefault = MACH_PORT_NULL;

EXPORT int IOMainPort(mach_port_t bootstrap, mach_port_t *main_port)
{
    (void)bootstrap;
    if (main_port)
        *main_port = MACH_PORT_NULL;
    return 0;
}

EXPORT CFMutableDictionaryRef IOServiceMatching(const char *name)
{
    (void)name;
    return CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                     &kCFTypeDictionaryValueCallBacks);
}

EXPORT unsigned int IOServiceGetMatchingService(mach_port_t main_port, CFDictionaryRef matching)
{
    (void)main_port;
    if (matching)
        CFRelease(matching); /* consumes one reference, like the real call */
    return 0;
}

EXPORT int IOServiceOpen(unsigned int service, mach_port_t task, uint32_t type, unsigned int *connect)
{
    (void)service;
    (void)task;
    (void)type;
    if (connect)
        *connect = 0;
    return kIOReturnUnsupported;
}

EXPORT int IOServiceClose(unsigned int connect)
{
    (void)connect;
    return 0;
}

EXPORT int IOObjectRelease(unsigned int object)
{
    (void)object;
    return 0;
}

EXPORT int IOHIDGetMouseAcceleration(unsigned int handle, double *accel)
{
    (void)handle;
    if (accel)
        *accel = 0;
    return kIOReturnUnsupported;
}

EXPORT int IOHIDSetMouseAcceleration(unsigned int handle, double accel)
{
    (void)handle;
    (void)accel;
    return kIOReturnUnsupported;
}

EXPORT CFTypeRef IOHIDManagerCreate(CFAllocatorRef alloc, uint32_t options)
{
    (void)options;
    return CFSetCreate(alloc, NULL, 0, &kCFTypeSetCallBacks); /* stand-in CF object */
}

EXPORT int IOHIDManagerOpen(CFTypeRef manager, uint32_t options)
{
    (void)manager;
    (void)options;
    return kIOReturnUnsupported;
}

EXPORT int IOHIDManagerClose(CFTypeRef manager, uint32_t options)
{
    (void)manager;
    (void)options;
    return 0;
}

EXPORT CFSetRef IOHIDManagerCopyDevices(CFTypeRef manager)
{
    (void)manager;
    return CFSetCreate(kCFAllocatorDefault, NULL, 0, &kCFTypeSetCallBacks);
}

EXPORT void IOHIDManagerSetDeviceMatching(CFTypeRef manager, CFDictionaryRef matching)
{
    (void)manager;
    (void)matching;
}

EXPORT void IOHIDManagerRegisterInputValueCallback(CFTypeRef manager, void *callback, void *context)
{
    (void)manager;
    (void)callback;
    (void)context;
}

EXPORT void IOHIDManagerScheduleWithRunLoop(CFTypeRef manager, CFRunLoopRef loop, CFStringRef mode)
{
    (void)manager;
    (void)loop;
    (void)mode;
}

EXPORT CFTypeRef IOHIDValueGetElement(CFTypeRef value)
{
    (void)value;
    return NULL;
}

EXPORT CFIndex IOHIDValueGetIntegerValue(CFTypeRef value)
{
    (void)value;
    return 0;
}

EXPORT uint32_t IOHIDElementGetUsage(CFTypeRef element)
{
    (void)element;
    return 0;
}

EXPORT uint32_t IOHIDElementGetUsagePage(CFTypeRef element)
{
    (void)element;
    return 0;
}
