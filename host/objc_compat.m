// Fill in the macOS-only Objective-C API that MetalDrv (built for macOS with
// metal-cpp) may call, so the unchanged renderer runs on iOS:
//  - explicit no-op / zero implementations for known macOS-only selectors;
//  - Managed storage (macOS only) is turned into Shared on iOS;
//  - any other selector these Metal classes do not know is logged once and
//    answered with 0 instead of throwing "unrecognized selector".
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include "bc_decode.h"
#include "host_common.h"

static id ret_zero(id self, SEL _cmd, ...) { (void)self; (void)_cmd; return 0; }
static void ret_void(id self, SEL _cmd, ...) { (void)self; (void)_cmd; }
static BOOL ret_yes(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }

static void add_if_missing(Class cls, const char *sel, IMP imp, const char *types)
{
    SEL s = sel_registerName(sel);
    if (!cls || class_getInstanceMethod(cls, s))
        return;
    class_addMethod(cls, s, imp, types);
    host_log("[objc] added -[%s %s]", class_getName(cls), sel);
}

// ---- Managed -> Shared ----------------------------------------------------
static const MTLResourceOptions kManagedOpt = (MTLResourceOptions)(1u << MTLResourceStorageModeShift); // MTLStorageModeManaged == 1

static MTLResourceOptions fix_opts(MTLResourceOptions o)
{
    if ((o & MTLResourceStorageModeMask) == kManagedOpt) {
        o &= ~MTLResourceStorageModeMask;
        o |= MTLResourceStorageModeShared;
    }
    return o;
}

static IMP g_newBufLen, g_newBufBytes, g_newBufNoCopy, g_newTex, g_newHeap;

// first few conversions of each kind are logged: shows what MetalDrv really
// creates as Managed (macOS-only storage) on a macOS or Catalyst test run
static int g_conv[5];
static const char *kConvName[5] = {"buffer", "buffer+bytes", "buffer nocopy", "texture", "heap"};

static void note(int kind, NSUInteger size)
{
    if (++g_conv[kind] <= 3 || g_conv[kind] == 100 || g_conv[kind] == 1000)
        host_log("[metal] managed->shared %s #%d (%lu bytes)", kConvName[kind], g_conv[kind], (unsigned long)size);
}

static MTLResourceOptions fix_opts_note(MTLResourceOptions o, int kind, NSUInteger size)
{
    if ((o & MTLResourceStorageModeMask) == kManagedOpt)
        note(kind, size);
    return fix_opts(o);
}

static id my_newBufLen(id self, SEL cmd, NSUInteger len, MTLResourceOptions o)
{
    return ((id(*)(id, SEL, NSUInteger, MTLResourceOptions))g_newBufLen)(self, cmd, len, fix_opts_note(o, 0, len));
}

static id my_newBufBytes(id self, SEL cmd, const void *p, NSUInteger len, MTLResourceOptions o)
{
    return ((id(*)(id, SEL, const void *, NSUInteger, MTLResourceOptions))g_newBufBytes)(self, cmd, p, len,
                                                                                       fix_opts_note(o, 1, len));
}

static id my_newBufNoCopy(id self, SEL cmd, void *p, NSUInteger len, MTLResourceOptions o, id dealloc)
{
    return ((id(*)(id, SEL, void *, NSUInteger, MTLResourceOptions, id))g_newBufNoCopy)(self, cmd, p, len,
                                                                                      fix_opts_note(o, 2, len), dealloc);
}

// ---- BC1-3 (DXT) fallback for GPUs without BC support ----------------------
static bool g_bc_decode;
static char kBCKey;
static IMP g_bcReplace4, g_bcReplace6;
static int g_bc_count;

static int bc_kind(MTLPixelFormat f)
{
    switch ((int)f) {
    case 130: case 131: return 1; // BC1_RGBA(_sRGB)
    case 132: case 133: return 2; // BC2
    case 134: case 135: return 3; // BC3
    default: return 0;
    }
}

static int tex_bc_kind(id tex)
{
    NSNumber *n = objc_getAssociatedObject(tex, &kBCKey);
    return n ? n.intValue : 0;
}

static void bc_replace6(id self, SEL cmd, MTLRegion r, NSUInteger lvl, NSUInteger slice, const void *b,
                        NSUInteger bpr, NSUInteger bpi)
{
    int k = tex_bc_kind(self);
    if (k && b) {
        size_t w = r.size.width, h = r.size.height;
        uint8_t *rgba = malloc(w * h * 4);
        bc_decode_rgba8(k, b, bpr, (int)w, (int)h, rgba);
        ((void (*)(id, SEL, MTLRegion, NSUInteger, NSUInteger, const void *, NSUInteger, NSUInteger))g_bcReplace6)(
            self, cmd, r, lvl, slice, rgba, w * 4, w * h * 4);
        free(rgba);
        return;
    }
    ((void (*)(id, SEL, MTLRegion, NSUInteger, NSUInteger, const void *, NSUInteger, NSUInteger))g_bcReplace6)(
        self, cmd, r, lvl, slice, b, bpr, bpi);
}

static void bc_replace4(id self, SEL cmd, MTLRegion r, NSUInteger lvl, const void *b, NSUInteger bpr)
{
    int k = tex_bc_kind(self);
    if (k && b) {
        size_t w = r.size.width, h = r.size.height;
        uint8_t *rgba = malloc(w * h * 4);
        bc_decode_rgba8(k, b, bpr, (int)w, (int)h, rgba);
        ((void (*)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger))g_bcReplace4)(self, cmd, r, lvl, rgba,
                                                                                         w * 4);
        free(rgba);
        return;
    }
    ((void (*)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger))g_bcReplace4)(self, cmd, r, lvl, b, bpr);
}

static id my_newTex(id self, SEL cmd, MTLTextureDescriptor *d)
{
    int bc = g_bc_decode ? bc_kind(d.pixelFormat) : 0;
    if (bc) {
        MTLPixelFormat orig = d.pixelFormat;
        d.pixelFormat = ((int)orig & 1) ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm;
        if (d.storageMode == (MTLStorageMode)1)
            d.storageMode = MTLStorageModeShared;
        id t = ((id(*)(id, SEL, MTLTextureDescriptor *))g_newTex)(self, cmd, d);
        d.pixelFormat = orig;
        if (t)
            objc_setAssociatedObject(t, &kBCKey, @(bc), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (++g_bc_count <= 2 || g_bc_count == 100)
            host_log("[metal] BC%d texture #%d %lux%lu -> RGBA8 (CPU decode)", bc, g_bc_count,
                     (unsigned long)d.width, (unsigned long)d.height);
        return t;
    }
    if (d.storageMode == (MTLStorageMode)1) { // Managed
        note(3, d.width * d.height);
        d.storageMode = MTLStorageModeShared;
    }
    if ((d.resourceOptions & MTLResourceStorageModeMask) == kManagedOpt)
        d.resourceOptions = fix_opts(d.resourceOptions);
    return ((id(*)(id, SEL, MTLTextureDescriptor *))g_newTex)(self, cmd, d);
}

static id my_newHeap(id self, SEL cmd, MTLHeapDescriptor *d)
{
    if (d.storageMode == (MTLStorageMode)1) {
        note(4, d.size);
        d.storageMode = MTLStorageModeShared;
    }
    return ((id(*)(id, SEL, MTLHeapDescriptor *))g_newHeap)(self, cmd, d);
}

static void hook(Class cls, const char *sel, IMP imp, IMP *orig)
{
    Method m = class_getInstanceMethod(cls, sel_registerName(sel));
    if (m)
        *orig = method_setImplementation(m, imp);
}

// ---- upload tracing (UT2004_TRACE_UPLOADS): how MetalDrv fills textures ----
static IMP g_replace4, g_replace6, g_blitBufTex;
static int g_trace_n;

static void trace(const char *what, id<MTLTexture> t)
{
    if (++g_trace_n <= 40)
        host_log("[metal] %s fmt %lu %lux%lu mips %lu storage %lu", what, (unsigned long)t.pixelFormat,
                 (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.mipmapLevelCount,
                 (unsigned long)t.storageMode);
}

static void my_replace4(id self, SEL cmd, MTLRegion r, NSUInteger lvl, const void *b, NSUInteger bpr)
{
    trace("replaceRegion", self);
    ((void (*)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger))g_replace4)(self, cmd, r, lvl, b, bpr);
}

static void my_replace6(id self, SEL cmd, MTLRegion r, NSUInteger lvl, NSUInteger slice, const void *b,
                        NSUInteger bpr, NSUInteger bpi)
{
    trace("replaceRegion:slice", self);
    ((void (*)(id, SEL, MTLRegion, NSUInteger, NSUInteger, const void *, NSUInteger, NSUInteger))g_replace6)(
        self, cmd, r, lvl, slice, b, bpr, bpi);
}

static void my_blitBufTex(id self, SEL cmd, id buf, NSUInteger off, NSUInteger bpr, NSUInteger bpi, MTLSize sz,
                          id tex, NSUInteger slice, NSUInteger lvl, MTLOrigin org)
{
    trace("blit buffer->texture", tex);
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin))
         g_blitBufTex)(self, cmd, buf, off, bpr, bpi, sz, tex, slice, lvl, org);
}

static void trace_uploads_install(id<MTLDevice> dev)
{
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:4 height:4 mipmapped:NO];
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    Class tc = object_getClass(t);
    hook(tc, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", (IMP)my_replace4, &g_replace4);
    hook(tc, "replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:", (IMP)my_replace6, &g_replace6);
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    hook(object_getClass(be),
         "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:",
         (IMP)my_blitBufTex, &g_blitBufTex);
    [be endEncoding];
    [t release];
    [q release];
    host_log("[metal] tracing texture uploads (%s)", class_getName(tc));
}



// ---- Metal pipeline cache --------------------------------------------------
// MetalDrv opens and saves its MTLBinaryArchive at
// [NSURL fileURLWithPath:@"MetalPipelineCache.bin"], relative to the working
// directory (the bundle's System folder). That folder is read-only on iOS:
// saving it aborted every map load. Move such URLs to Library/Caches/UT2004.
static IMP g_archSetUrl, g_archSerialize;
static NSString *g_cache_dir, *g_bundle_sys;

static NSURL *cache_url(NSURL *url)
{
    if (!url || !url.isFileURL || !g_cache_dir)
        return url;
    NSString *path = url.path;
    // resolve the parent (exists) so /private/var and /var compare equal
    NSString *parent = [[path stringByDeletingLastPathComponent] stringByResolvingSymlinksInPath];
    if (![parent isEqualToString:g_bundle_sys])
        return url;
    NSString *dest = [g_cache_dir stringByAppendingPathComponent:path.lastPathComponent];
    host_log("[metal] pipeline cache %s -> %s", path.UTF8String, dest.UTF8String);
    return [NSURL fileURLWithPath:dest];
}

static void my_archSetUrl(id self, SEL cmd, NSURL *url)
{
    ((void (*)(id, SEL, NSURL *))g_archSetUrl)(self, cmd, cache_url(url));
}

static BOOL my_archSerialize(id self, SEL cmd, NSURL *url, NSError **err)
{
    // A failed save only costs shader compile time; never let it end the game.
    @try {
        return ((BOOL(*)(id, SEL, NSURL *, NSError **))g_archSerialize)(self, cmd, cache_url(url), err);
    } @catch (NSException *e) {
        host_log("[metal] pipeline cache save failed: %s", e.reason.UTF8String);
        if (err)
            *err = nil;
        return NO;
    }
}

static void pipeline_cache_install(id<MTLDevice> dev)
{
    const char *home = getenv("HOME");
    NSString *h = home && *home ? @(home) : NSHomeDirectory();
    g_cache_dir = [[h stringByAppendingPathComponent:@"Library/Caches/UT2004"] retain];
    [[NSFileManager defaultManager] createDirectoryAtPath:g_cache_dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    g_bundle_sys = [[[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"System"]
        stringByResolvingSymlinksInPath] retain];

    hook([MTLBinaryArchiveDescriptor class], "setUrl:", (IMP)my_archSetUrl, &g_archSetUrl);
    MTLBinaryArchiveDescriptor *d = [[MTLBinaryArchiveDescriptor new] autorelease];
    NSError *err = nil;
    id<MTLBinaryArchive> a = [dev newBinaryArchiveWithDescriptor:d error:&err];
    if (a) {
        hook(object_getClass(a), "serializeToURL:error:", (IMP)my_archSerialize, &g_archSerialize);
        [a release];
    }
    host_log("[metal] pipeline cache redirect: setUrl %s, serialize %s", g_archSetUrl ? "hooked" : "NOT hooked",
             g_archSerialize ? "hooked" : "NOT hooked");
}

// ---- frame counter ---------------------------------------------------------
// Logs presented frames per second every 5 s with the drawable size and the
// longest frame, so frame rate can be read from the host log on a device.
static IMP g_nextDrawable;
static int g_frames;
static double g_frames_t0, g_last_frame, g_worst_ms;

static id my_nextDrawable(id self, SEL cmd)
{
    id d = ((id(*)(id, SEL))g_nextDrawable)(self, cmd);
    double now = CACurrentMediaTime();
    if (g_last_frame > 0 && (now - g_last_frame) * 1000.0 > g_worst_ms)
        g_worst_ms = (now - g_last_frame) * 1000.0;
    g_last_frame = now;
    if (g_frames_t0 == 0)
        g_frames_t0 = now;
    g_frames++;
    if (now - g_frames_t0 >= 5.0) {
        CGSize s = ((CAMetalLayer *)self).drawableSize;
        host_log("[fps] %.1f (%dx%d, worst frame %.0f ms)", g_frames / (now - g_frames_t0), (int)s.width,
                 (int)s.height, g_worst_ms);
        g_frames = 0;
        g_frames_t0 = now;
        g_worst_ms = 0;
    }
    return d;
}

// ---- unknown selector safety net -----------------------------------------
@interface UTZeroResponder : NSObject
@end
@implementation UTZeroResponder
+ (BOOL)resolveInstanceMethod:(SEL)sel
{
    host_log("[objc] WARNING: unimplemented macOS selector %s -> 0", sel_getName(sel));
    class_addMethod(self, sel, (IMP)ret_zero, "@@:");
    return YES;
}
@end

static UTZeroResponder *g_zero;
static IMP g_fwd_orig[16];
static Class g_fwd_cls[16];
static int g_fwd_count;

static id fwd_target(id self, SEL _cmd, SEL sel)
{
    Class c = object_getClass(self);
    for (int i = 0; i < g_fwd_count; i++) {
        if (c == g_fwd_cls[i] || [c isSubclassOfClass:g_fwd_cls[i]]) {
            id t = ((id(*)(id, SEL, SEL))g_fwd_orig[i])(self, _cmd, sel);
            if (t)
                return t;
            break;
        }
    }
    host_log("[objc] -[%s %s] not available on iOS", class_getName(c), sel_getName(sel));
    return g_zero;
}

static void safety_net(Class cls)
{
    if (!cls || g_fwd_count >= 16)
        return;
    SEL s = @selector(forwardingTargetForSelector:);
    Method own = NULL;
    unsigned n = 0;
    Method *list = class_copyMethodList(cls, &n);
    for (unsigned i = 0; i < n; i++)
        if (method_getName(list[i]) == s)
            own = list[i];
    free(list);
    IMP super_imp = class_getMethodImplementation(cls, s);
    if (own)
        g_fwd_orig[g_fwd_count] = method_setImplementation(own, (IMP)fwd_target);
    else {
        g_fwd_orig[g_fwd_count] = super_imp;
        class_addMethod(cls, s, (IMP)fwd_target, "@@::");
    }
    g_fwd_cls[g_fwd_count++] = cls;
}

void ut_objc_compat_install(void)
{
    g_zero = [UTZeroResponder new];

    Class layer = [CAMetalLayer class];
    add_if_missing(layer, "displaySyncEnabled", (IMP)ret_yes, "B@:");
    add_if_missing(layer, "setDisplaySyncEnabled:", (IMP)ret_void, "v@:B");
    add_if_missing(layer, "wantsExtendedDynamicRangeContent", (IMP)ret_zero, "B@:");
    add_if_missing(layer, "setWantsExtendedDynamicRangeContent:", (IMP)ret_void, "v@:B");
    hook(layer, "nextDrawable", (IMP)my_nextDrawable, &g_nextDrawable);
    safety_net(layer);

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) {
        host_log("[objc] no Metal device");
        return;
    }
    Class dc = object_getClass(dev);
    static const char *bools[] = {"isLowPower", "isHeadless", "isRemovable",
                                  "isDepth24Stencil8PixelFormatSupported"};
    static const char *ints[] = {"location", "locationNumber", "maxTransferRate",
                                 "peerGroupID", "peerIndex", "peerCount"};
    for (size_t i = 0; i < sizeof bools / sizeof *bools; i++)
        add_if_missing(dc, bools[i], (IMP)ret_zero, "B@:");
    for (size_t i = 0; i < sizeof ints / sizeof *ints; i++)
        add_if_missing(dc, ints[i], (IMP)ret_zero, "Q@:");
    hook(dc, "newBufferWithLength:options:", (IMP)my_newBufLen, &g_newBufLen);
    hook(dc, "newBufferWithBytes:length:options:", (IMP)my_newBufBytes, &g_newBufBytes);
    hook(dc, "newTextureWithDescriptor:", (IMP)my_newTex, &g_newTex);
    hook(dc, "newBufferWithBytesNoCopy:length:options:deallocator:", (IMP)my_newBufNoCopy, &g_newBufNoCopy);
    hook(dc, "newHeapWithDescriptor:", (IMP)my_newHeap, &g_newHeap);
    if (getenv("UT2004_TRACE_UPLOADS"))
        trace_uploads_install(dev);
    pipeline_cache_install(dev);
    bool bc_native = false;
    if (@available(iOS 16.4, macOS 11.0, *))
        bc_native = dev.supportsBCTextureCompression;
    g_bc_decode = getenv("UT2004_FORCE_BC_DECODE") != NULL || !bc_native;
    host_log("[metal] %s: BC textures %s", dev.name.UTF8String,
             g_bc_decode ? "decoded on the CPU (no GPU support)" : "native");
    if (g_bc_decode) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:4 height:4 mipmapped:NO];
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        Class tc = object_getClass(t);
        hook(tc, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", (IMP)bc_replace4, &g_bcReplace4);
        hook(tc, "replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:", (IMP)bc_replace6,
             &g_bcReplace6);
        [t release];
    }
    safety_net(dc);

    id<MTLBuffer> buf = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    Class bc = object_getClass(buf);
    add_if_missing(bc, "didModifyRange:", (IMP)ret_void, "v@:{_NSRange=QQ}");
    safety_net(bc);

    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    Class ec = object_getClass(blit);
    add_if_missing(ec, "synchronizeResource:", (IMP)ret_void, "v@:@");
    add_if_missing(ec, "synchronizeTexture:slice:level:", (IMP)ret_void, "v@:@QQ");
    safety_net(ec);
    [blit endEncoding];

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    rp.colorAttachments[0].texture = rt;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    Class rc = object_getClass(re);
    add_if_missing(rc, "textureBarrier", (IMP)ret_void, "v@:");
    safety_net(rc);
    [re endEncoding];
    safety_net(object_getClass(cb));
    safety_net(object_getClass(rt));
    [cb commit];

    [rt release];
    [q release];
    [buf release];
    [dev release];
}
