// macOS test host. Same flat bundle, shims, Metal
// compatibility layer and launch path as the iOS host (host/ios/ios_main.m);
// only UIKit/SDL_RunApp is missing. Set HOME so the game data folder
// ($HOME/Library/Application Support/UT2004) points where you want it.
#import <Foundation/Foundation.h>

#include "../host/host_common.h"

int main(int argc, char **argv, char **envp)
{
    @autoreleasepool {
        const char *log = getenv("UT2004_HOST_LOG");
        if (log)
            host_open_log(log);
        ut_objc_compat_install();
    }
    return host_run_game(argc, argv, envp);
}
