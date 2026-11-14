// iOS host for OldUnreal's UT2004 (patch 3374, Apple Silicon build).
//
// SDL_RunApp starts UIKit (scene delegate from SDL); SDL then calls
// game_entry on the main thread. We prepare the folders, install the Metal
// compatibility layer and run OldUnreal's own launcher main() (UT2004Main.dylib)
// on a 256 MB stack — iOS gives the main thread only 1 MB.
//
// Folders (Files app: On My iPhone > UT2004):
//   Documents/UT2004/      game data copied by the user + the game's own
//                          System/ (UT2004.ini, User.ini, logs), Save/, Cache/
//   Library/Application Support/UT2004 -> Documents/UT2004 (the game's
//                          per-user folder, $HOME/Library/Application Support)
//   Documents/UT2004-host.log, Documents/UT2004-stdout.log
#define SDL_MAIN_HANDLED
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3/SDL_ut2004.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../host_common.h"
#include "touch_controls.h"

extern char **environ;

static const char *kRequiredData[] = {
    "Animations", "KarmaData", "Maps", "Music", "Sounds", "StaticMeshes", "Textures",
};

// UT2004_DOCS overrides Documents (Mac Catalyst test runs, mac/run_catalyst.sh).
static NSString *docs_dir(void)
{
    const char *test = getenv("UT2004_DOCS");
    if (test && *test)
        return @(test);
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// The game finds its user folder through $HOME (on iOS: the app container).
static NSString *home_dir(void)
{
    const char *home = getenv("HOME");
    return home && *home ? @(home) : NSHomeDirectory();
}

static void redirect_stdio(NSString *docs)
{
    NSString *log = [docs stringByAppendingPathComponent:@"UT2004-stdout.log"];
    NSString *prev = [docs stringByAppendingPathComponent:@"UT2004-stdout.prev.log"];
    [[NSFileManager defaultManager] removeItemAtPath:prev error:nil];
    [[NSFileManager defaultManager] moveItemAtPath:log toPath:prev error:nil];
    freopen(log.fileSystemRepresentation, "w", stdout);
    dup2(fileno(stdout), fileno(stderr));
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

// The game reads/writes $HOME/Library/Application Support/UT2004. Point that
// at Documents/UT2004 so the user can drop the game data in with Files/Finder.
static NSString *prepare_game_dir(NSString *docs)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *game = [docs stringByAppendingPathComponent:@"UT2004"];
    [fm createDirectoryAtPath:game withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *support = [home_dir() stringByAppendingPathComponent:@"Library/Application Support"];
    [fm createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *link = [support stringByAppendingPathComponent:@"UT2004"];
    NSString *dest = [fm destinationOfSymbolicLinkAtPath:link error:nil];
    if (![dest isEqualToString:game]) {
        [fm removeItemAtPath:link error:nil];
        NSError *err = nil;
        if (![fm createSymbolicLinkAtPath:link withDestinationPath:game error:&err])
            host_log("[host] symlink %s failed: %s", link.UTF8String, err.localizedDescription.UTF8String);
    }
    return game;
}

static NSString *missing_data(NSString *game)
{
    NSMutableArray *missing = [NSMutableArray array];
    for (size_t i = 0; i < sizeof kRequiredData / sizeof *kRequiredData; i++) {
        NSString *p = [game stringByAppendingPathComponent:@(kRequiredData[i])];
        BOOL dir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&dir] || !dir)
            [missing addObject:@(kRequiredData[i])];
    }
    return missing.count ? [missing componentsJoinedByString:@", "] : nil;
}

// Sets key=value inside [section] of an ini text (adds the key if missing).
static NSString *ini_set(NSString *text, NSString *section, NSString *key, NSString *value, NSString *eol)
{
    NSMutableArray<NSString *> *lines = [[[text componentsSeparatedByString:@"\n"] mutableCopy] autorelease];
    NSString *header = [NSString stringWithFormat:@"[%@]", section];
    NSString *prefix = [key stringByAppendingString:@"="];
    BOOL cr = [eol isEqualToString:@"\r\n"];
    NSString *entry = [NSString stringWithFormat:@"%@%@%@", prefix, value, cr ? @"\r" : @""];
    NSInteger start = -1;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *l = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (start < 0) {
            if ([l caseInsensitiveCompare:header] == NSOrderedSame)
                start = (NSInteger)i;
            continue;
        }
        if ([l hasPrefix:@"["])
            break;
        if (l.length >= prefix.length && [[l substringToIndex:prefix.length] caseInsensitiveCompare:prefix] == NSOrderedSame) {
            lines[i] = entry;
            return [lines componentsJoinedByString:@"\n"];
        }
    }
    if (start < 0) {
        [lines addObject:cr ? [header stringByAppendingString:@"\r"] : header];
        start = (NSInteger)lines.count - 1;
    }
    [lines insertObject:entry atIndex:(NSUInteger)start + 1];
    return [lines componentsJoinedByString:@"\n"];
}

// Value of key in [section], or nil.
static NSString *ini_get(NSString *text, NSString *section, NSString *key)
{
    NSString *header = [NSString stringWithFormat:@"[%@]", section];
    NSString *prefix = [key stringByAppendingString:@"="];
    BOOL in = NO;
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([l hasPrefix:@"["]) {
            in = [l caseInsensitiveCompare:header] == NSOrderedSame;
            continue;
        }
        if (in && l.length >= prefix.length &&
            [[l substringToIndex:prefix.length] caseInsensitiveCompare:prefix] == NSOrderedSame)
            return [l substringFromIndex:prefix.length];
    }
    return nil;
}

typedef struct {
    NSString *path, *text, *eol;
    NSStringEncoding enc;
    BOOL utf16;
} IniFile;

// Opens System/<name>, first copying System/<def> from the bundle when it does
// not exist yet (the game does the same; doing it first keeps our keys from
// creating a stub file).
static BOOL ini_open(NSString *sys, NSString *name, NSString *def, IniFile *f)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:sys withIntermediateDirectories:YES attributes:nil error:nil];
    f->path = [sys stringByAppendingPathComponent:name];
    if (![fm fileExistsAtPath:f->path]) {
        NSString *src = [[NSBundle mainBundle].bundlePath
            stringByAppendingPathComponent:[@"System" stringByAppendingPathComponent:def]];
        NSError *err = nil;
        if (![fm copyItemAtPath:src toPath:f->path error:&err]) {
            host_log("[host] copy %s failed: %s", def.UTF8String, err.localizedDescription.UTF8String);
            return NO;
        }
    }
    NSData *data = [NSData dataWithContentsOfFile:f->path];
    const unsigned char *b = data.bytes;
    f->utf16 = data.length >= 2 && b[0] == 0xFF && b[1] == 0xFE;
    f->enc = f->utf16 ? NSUTF16LittleEndianStringEncoding : NSUTF8StringEncoding;
    f->text = [[[NSString alloc] initWithData:(f->utf16 ? [data subdataWithRange:NSMakeRange(2, data.length - 2)] : data)
                                     encoding:f->enc] autorelease];
    if (!f->text && !f->utf16) {
        f->enc = NSISOLatin1StringEncoding;
        f->text = [[[NSString alloc] initWithData:data encoding:f->enc] autorelease];
    }
    if (!f->text) {
        host_log("[host] cannot read %s", f->path.UTF8String);
        return NO;
    }
    f->eol = [f->text containsString:@"\r\n"] ? @"\r\n" : @"\n";
    return YES;
}

static void ini_save(IniFile *f, NSString *text)
{
    if ([text isEqualToString:f->text])
        return;
    NSMutableData *bytes = [NSMutableData data];
    if (f->utf16)
        [bytes appendBytes:"\xFF\xFE" length:2];
    [bytes appendData:[text dataUsingEncoding:f->enc]];
    NSError *err = nil;
    if (![bytes writeToFile:f->path options:NSDataWritingAtomic error:&err])
        host_log("[host] write %s failed: %s", f->path.UTF8String, err.localizedDescription.UTF8String);
}

static NSString *random_hex(int n)
{
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < n; i++)
        [s appendFormat:@"%x", arc4random_uniform(16)];
    return s;
}

// Render below native resolution: UT2004's GUI fonts and list rows are sized
// in pixels, so at 3x (2868x1320) menus are tiny and corner buttons hard to
// hit; at 2x they are 1.5x larger and the GPU fills 2.25x fewer pixels.
// SDL (SDL_UT_SetPixelScale) and the game's resolution use the same factor so
// the whole frame is drawn; UIKit scales it up to the screen.
static const double kRenderScale = 2.0 / 3.0;

static double render_scale(void)
{
    const char *sc = getenv("UT2004_RENDER_SCALE"); // tests
    if (sc && atof(sc) >= 0.25 && atof(sc) <= 1.0)
        return atof(sc);
    return kRenderScale;
}

// SDLDrv opens its window at the configured viewport size and MetalDrv sizes
// the drawable to it. Set every SDLClient size to the screen's landscape pixel
// size (times the render scale) on each launch; the game's default 640x480
// came out squashed and blurry.
static void fit_viewport_to_screen(NSString *game)
{
    CGRect nb = [UIScreen mainScreen].nativeBounds;
    double scale = render_scale();
    int w = (int)(MAX(nb.size.width, nb.size.height) * scale + 0.5);
    int h = (int)(MIN(nb.size.width, nb.size.height) * scale + 0.5);
    const char *ovr = getenv("UT2004_RES"); // "WxH" (tests)
    if (ovr && sscanf(ovr, "%dx%d", &w, &h) != 2)
        w = h = 0;
    if (w < 320 || h < 240) {
        host_log("[host] screen size unknown (%dx%d); viewport left as configured", w, h);
        return;
    }

    IniFile f;
    if (!ini_open([game stringByAppendingPathComponent:@"System"], @"UT2004.ini", @"Default.ini", &f))
        return;
    NSString *sw = [NSString stringWithFormat:@"%d", w], *sh = [NSString stringWithFormat:@"%d", h];
    NSString *out = f.text;
    for (NSString *k in @[ @"Windowed", @"Fullscreen", @"Menu" ]) {
        out = ini_set(out, @"SDLDrv.SDLClient", [k stringByAppendingString:@"ViewportX"], sw, f.eol);
        out = ini_set(out, @"SDLDrv.SDLClient", [k stringByAppendingString:@"ViewportY"], sh, f.eol);
    }
    ini_save(&f, out);
    host_log("[host] viewport %dx%d (%s)", w, h, f.path.UTF8String);
}

// One-time online defaults (System/iOSDefaults-1 marks them as applied, so
// later changes in the game's settings stay):
//  - Track Stats on with a random username/password. Most servers now run
//    stats and refuse clients without it (FailCode NEEDSTATS); the game's own
//    prompt then needs typing a name and password on a touch screen.
//  - Internet net speed 20000 (DefUser.ini's value). UE2 caps a client's
//    frame rate at netspeed / 42, so the 2600 "modem" setting meant ~60 fps.
//  - Online frame cap 120 (LevelInfo.MaxClientFrameRate, default 90).
static void apply_online_defaults(NSString *game)
{
    NSString *sys = [game stringByAppendingPathComponent:@"System"];

    // Voice chat off on every launch: joining a server with UseVoIP=True
    // opens an OpenAL capture device, and iOS kills the app from TCC (abort
    // in a TCC dispatch callback) right after "ALAudio: Couldn't find a means
    // to record audio". The audio session is playback-only, so it could not
    // record anyway.
    IniFile a;
    if (ini_open(sys, @"UT2004.ini", @"Default.ini", &a) &&
        ![ini_get(a.text, @"ALAudio.ALAudioSubsystem", @"UseVoIP") isEqualToString:@"False"]) {
        ini_save(&a, ini_set(a.text, @"ALAudio.ALAudioSubsystem", @"UseVoIP", @"False", a.eol));
        host_log("[host] voice chat off (UseVoIP=False)");
    }

    NSString *marker = [sys stringByAppendingPathComponent:@"iOSDefaults-1"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:marker])
        return;

    IniFile u;
    if (!ini_open(sys, @"User.ini", @"DefUser.ini", &u))
        return;
    NSString *out = u.text;
    NSString *pc = @"Engine.PlayerController";
    if (!ini_get(out, pc, @"StatsUsername").length)
        out = ini_set(out, pc, @"StatsUsername", [@"ios" stringByAppendingString:random_hex(9)], u.eol);
    if (!ini_get(out, pc, @"StatsPassword").length)
        out = ini_set(out, pc, @"StatsPassword", random_hex(12), u.eol);
    out = ini_set(out, pc, @"bEnableStatsTracking", @"True", u.eol);
    out = ini_set(out, @"Engine.Player", @"ConfiguredInternetSpeed", @"20000", u.eol);
    ini_save(&u, out);

    IniFile g;
    if (!ini_open(sys, @"UT2004.ini", @"Default.ini", &g))
        return;
    ini_save(&g, ini_set(g.text, @"Engine.LevelInfo", @"MaxClientFrameRate", @"120.0", g.eol));

    [[NSData data] writeToFile:marker atomically:YES];
    host_log("[host] online defaults applied (stats on, netspeed 20000, online cap 120)");
}

static int game_entry(int argc, char **argv)
{
    @autoreleasepool {
        NSString *docs = docs_dir();
        redirect_stdio(docs);
        host_open_log([docs stringByAppendingPathComponent:@"UT2004-host.log"].fileSystemRepresentation);
        host_log("[host] UT2004 iOS host, bundle %s", [NSBundle mainBundle].bundlePath.UTF8String);

        NSString *game = prepare_game_dir(docs);
        NSString *missing = missing_data(game);
        if (missing) {
            NSString *msg = [NSString stringWithFormat:
                @"Game data not found.\n\nCopy these folders from Unreal Tournament 2004 into "
                @"Files > On My iPhone > UT2004 > UT2004, then start the app again:\n\n%@\n\n"
                @"(Help and Speech are optional. Do not copy the System folder.)", missing];
            host_log("[host] missing game data: %s", missing.UTF8String);
            bool shown = SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_INFORMATION, "UT2004", msg.UTF8String, NULL);
            host_log("[host] message box %s%s", shown ? "shown" : "failed: ", shown ? "" : SDL_GetError());
            exit(0); // nothing to run; next launch checks again
        }

        fit_viewport_to_screen(game);
        apply_online_defaults(game);

        double pscale = [UIScreen mainScreen].nativeScale * render_scale();
        const char *ps = getenv("UT2004_PIXEL_SCALE"); // tests (Mac Catalyst windows)
        if (ps && atof(ps) > 0.25)
            pscale = atof(ps);
        if (SDL_UT_SetPixelScale((float)pscale))
            host_log("[host] pixel scale %.3f", pscale);
        else
            host_log("[host] pixel scale failed: %s", SDL_GetError());

        // Game audio plays with the silent switch on and stops other audio
        // (OpenAL Soft's CoreAudio backend does not configure the session).
        NSError *aerr = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (![session setCategory:AVAudioSessionCategoryPlayback error:&aerr] || ![session setActive:YES error:&aerr])
            host_log("[host] audio session: %s", aerr.localizedDescription.UTF8String);

        SDL_SetHint(SDL_HINT_ORIENTATIONS, "LandscapeLeft LandscapeRight");
        SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "2");
        ut_objc_compat_install();
        ut_touch_controls_start();
    }
    // OldUnreal's launcher opens a splash window first; UIKit allows one SDL
    // window per screen, which SDLDrv then needs for the game.
    // Appended: UE2 takes the first command-line token as the map URL unless
    // it starts with '-'.
    char **args = calloc((size_t)argc + 2, sizeof *args);
    for (int i = 0; i < argc; i++)
        args[i] = argv[i];
    args[argc] = "-nosplash";
    int rc = host_run_game(argc + 1, args, environ);
    host_log("[host] exiting (%d)", rc);
    exit(rc); // UIApplicationMain never returns; quit the app with the game
}

int main(int argc, char **argv)
{
    return SDL_RunApp(argc, argv, game_entry, NULL);
}
