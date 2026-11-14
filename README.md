# UT2004 for iOS

Runs Unreal Tournament 2004 natively on iPhone/iPad using OldUnreal's
official patch 3374 (released with Epic's approval). No emulator and no JIT:
OldUnreal ships Apple Silicon (arm64) builds of every engine module, and this
project re-labels that machine code for iOS and links it against iOS
libraries.

Nothing from the game or from OldUnreal's binaries is stored in this
repository. You need OldUnreal's macOS patch (`OldUnreal-UT2004Patch3374-macOS.dmg`
from https://github.com/OldUnreal/UT2004Patches/releases) and the game data
(OldUnreal's free installer, or your own copy).

## How it works

| Piece | What happens |
|---|---|
| Engine modules (`Core`, `Engine`, `XGame`, `MetalDrv`, ...) | `lipo -thin arm64`, unsigned, `vtool` platform macOS -> iOS, framework paths remapped (`build.sh`) |
| OldUnreal launcher (`UT2004` executable) | turned into `UT2004Main.dylib` (`tools/machotool.py exe2dylib`), loaded by our host |
| Host app (`host/ios`) | `SDL_RunApp` starts UIKit; then the launcher's `main()` runs on a 256 MB stack (iOS main thread has 1 MB) |
| SDL3, OpenAL Soft | rebuilt for iOS as dylibs (`tools/build_deps.sh`), same ABI; SDL gets the small `sdl_ext` input extension |
| macOS-only calls | small shim dylibs: Carbon alert, `Gestalt`, IOKit HID/mouse acceleration, speech; MetalDrv's two device-observer calls are rebound to the Carbon shim (`machotool rebind`) |
| Metal on iOS | `host/ios/objc_compat.m` adds macOS-only selectors, maps Managed storage to Shared, and logs (instead of crashing on) any other missing selector |
| Paths | Core's `/Contents/MacOS` -> `/Contents/Resources/System/` rule patched to `.app` -> `.app/System/`; game data lives in `Documents/UT2004` |
| Renderer | `Default.ini` set to `MetalDrv.MetalRenderDevice` + `SDLDrv.SDLClient`, windowed (`StartupFullscreen=False`; the SDL window fills the screen on iOS) |
| Menus vs gameplay | `host/game_state.c` reads `UPlayer::bShowWindowsMouse` (set by the GUI in windowed mode) through Core's `StaticFindObject` and calls SDLDrv's `SetMouseCapture`: absolute pointer in menus, relative look in gameplay |
| Touch | `host/ios/touch_controls.m`: menus = finger is the pointer; gameplay = left stick (WASD), drag to look, FIRE/ALT/JUMP/DUCK/weapon/USE/SCORE/MENU/keyboard buttons; hidden while a controller is connected. Input goes through SDL's own pipeline (`sdl_ext/SDL_ut2004.c`) |
| UIKit fixes | `-nosplash` appended (the launcher's splash window would take UIKit's only window); relative-mouse fallback installed via a hint callback (SDLDrv asserts that relative mode works) |
| DXT textures | if the GPU reports no BC support, BC1-3 textures are created as RGBA8 and decoded on the CPU at upload (`host/bc_decode.c`) |
| Audio | iOS OpenAL Soft (CoreAudio); `AVAudioSession` category Playback; voice chat off (`UseVoIP=False`) |

## Build

```sh
PLATFORM=ios tools/build_deps.sh <SDL3 source> <openal-soft source> deps-ios
DEPS=deps-ios PLATFORM=ios ./build.sh /Volumes/<mounted dmg>/UT2004.app out
# -> out/UT2004-iOS-<version>-<build>.ipa (ad-hoc signed; re-sign to install)
```

Optional build settings: `BUNDLE_ID` (default `com.devz.ut04`), `VERSION`,
`BUILD`, `SIGN_ID`/`PROFILE` for signing, and `ICON=<1024x1024 png>` for an
app icon (none is included here). `PLATFORM=macos DEPS=deps-mac ./build.sh ...`
builds the same layout for macOS, for testing on a Mac.

Runtime switches: `UT2004_RENDER_SCALE` (default 0.667 of the native
resolution), `UT2004_RES=WxH`, `UT2004_STACKDUMP=<seconds,...>` (thread stack
dumps), `UT2004_FORCE_BC_DECODE=1` (CPU DXT path).

`tools/is_extract.py` extracts the game data from OldUnreal's UT2004 ISO
(InstallShield cabinets) without running any installer.

## Game data on the device

Copy these folders into Files > On My iPhone > UT2004 > UT2004:
Animations, KarmaData, Maps, Music, Sounds, StaticMeshes, Textures
(Help and Speech optional). Do not copy the original System folder.
Logs: `Documents/UT2004-host.log`, `Documents/UT2004-stdout.log`,
and the game's own log in `Documents/UT2004/System/`.
