#!/bin/bash
# Build UT2004 from OldUnreal's macOS patch bundle (3374, arm64).
#
#   PLATFORM=ios   (default) -> <out>/Payload/UT2004.app + <out>/UT2004-iOS-<ver>-<build>.ipa
#   PLATFORM=macos           -> <out>/UT2004.app, the SAME flat layout, shims and host logic
#                               as iOS, for testing on a Mac (run <out>/UT2004.app/UT2004)
#
# usage: build.sh <OldUnreal UT2004.app> <out dir>
# env:   DEPS (tools/build_deps.sh output for the same PLATFORM), BUNDLE_ID (com.devz.ut04),
#        VERSION (0.1.0), BUILD (1), SIGN_ID ("-" = ad-hoc), PROFILE (optional),
#        ICON (optional 1024x1024 PNG for the app icon; not part of this repo),
#        DEVTOOLS (optional dir with extra host test sources, e.g. autoinput.c)
#
# Nothing is emulated or JIT-compiled: OldUnreal's arm64 machine code is
# re-labelled for iOS and linked against iOS libraries (README.md).
set -euo pipefail
SRC_APP=${1:?OldUnreal UT2004.app (macOS)}
OUT=${2:?output dir}
HERE=$(cd "$(dirname "$0")" && pwd)
PLATFORM=${PLATFORM:-ios}
BUNDLE_ID=${BUNDLE_ID:-com.devz.ut04}
VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-1}
SIGN_ID=${SIGN_ID:--}
MT="python3 -I $HERE/tools/machotool.py"
MODULES=(Core Engine IpDrv Fire Editor XGame XInterface Onslaught UWeb UTV2004 SDLDrv MetalDrv ALAudio)

case "$PLATFORM" in
  ios)
    DEPS=${DEPS:?set DEPS to the PLATFORM=ios output of tools/build_deps.sh}
    MIN_OS=16.0
    SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    SDK_VER=$(xcrun --sdk iphoneos --show-sdk-version)
    CC=(xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=$MIN_OS)
    APP="$OUT/Payload/UT2004.app"
    SDL_INC="$DEPS/include" ;;
  macos)
    DEPS=${DEPS:?set DEPS to the PLATFORM=macos output of tools/build_deps.sh}
    MIN_OS=11.0
    SDK=$(xcrun --sdk macosx --show-sdk-path)
    CC=(xcrun --sdk macosx clang -arch arm64 -isysroot "$SDK" -mmacosx-version-min=$MIN_OS)
    APP="$OUT/UT2004.app"
    SDL_INC="$DEPS/include" ;;
  *) echo "PLATFORM must be ios or macos"; exit 1 ;;
esac
CC+=(-O2 -g -Wall -Wextra -Wno-unused-parameter -I"$HERE/host")
WORK="$OUT/work"
FW="$APP/Frameworks"
rm -rf "$WORK" "$APP" "$OUT/Payload"
mkdir -p "$WORK" "$FW"

remap() {
  local args=(
    -change /System/Library/Frameworks/Carbon.framework/Versions/A/Carbon @rpath/libShimCarbon.dylib
    -change /System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices @rpath/libShimCoreServices.dylib
    -change /System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices @rpath/libShimApplicationServices.dylib
    -change /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit @rpath/libShimIOKit.dylib
    -change @executable_path/../Frameworks/libSDL3.0.dylib @rpath/libSDL3.0.dylib
    -change @rpath/libopenal.1.24.3.dylib @rpath/libopenal.1.dylib
    -rpath @executable_path/../Frameworks @executable_path/Frameworks)
  if [ "$PLATFORM" = ios ]; then
    args+=(
      -change /System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa /System/Library/Frameworks/UIKit.framework/UIKit
      -change /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation
      -change /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation /System/Library/Frameworks/Foundation.framework/Foundation
      -change /System/Library/Frameworks/Metal.framework/Versions/A/Metal /System/Library/Frameworks/Metal.framework/Metal
      -change /System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore /System/Library/Frameworks/QuartzCore.framework/QuartzCore)
  fi
  install_name_tool "${args[@]}" "$1" 2>&1 | grep -v 'will invalidate the code signature' || true
}

convert() { # <name in Contents/MacOS> <output name>
  local src="$SRC_APP/Contents/MacOS/$1" t="$WORK/$2"
  lipo -thin arm64 "$src" -output "$t.thin"
  codesign --remove-signature "$t.thin"
  case "$1" in
    UT2004)   $MT exe2dylib "$t.thin" "$t.step" @rpath/UT2004Main.dylib ;;
    MetalDrv.dylib)
              $MT rebind "$t.thin" "$t.step" /System/Library/Frameworks/Carbon.framework/Versions/A/Carbon \
                  _MTLCopyAllDevicesWithObserver _MTLRemoveDeviceObserver ;;
    Core.dylib)
              # appChdirSystem: <exe dir>/Contents/MacOS -> .../Contents/Resources/System/
              # becomes  .../UT2004.app -> .../UT2004.app/System/
              $MT patchstr "$t.thin" "$t.step" '/Contents/MacOS=.app' '/Contents/Resources/System/=.app/System/' ;;
    *)        cp "$t.thin" "$t.step" ;;
  esac
  if [ "$PLATFORM" = ios ]; then
    xcrun vtool -set-build-version ios $MIN_OS "$SDK_VER" -replace -output "$t" "$t.step" 2>/dev/null
  else
    cp "$t.step" "$t"
  fi
  remap "$t"
  rm -f "$t.thin" "$t.step"
  cp "$t" "$FW/$2"
}

echo "== engine (OldUnreal arm64 -> $PLATFORM)"
convert UT2004 UT2004Main.dylib
for m in "${MODULES[@]}"; do convert "$m.dylib" "$m.dylib"; done

echo "== SDL3 / OpenAL"
if [ "$PLATFORM" = ios ]; then
  cp "$DEPS/lib/libSDL3.0.dylib" "$DEPS/lib/libopenal.1.dylib" "$FW/"
  SDL_LIB="$DEPS/lib/libSDL3.0.dylib"
else
  # same SDL 3.5 + UT2004 extension as iOS; OldUnreal's own OpenAL
  cp "$DEPS/lib/libSDL3.0.dylib" "$FW/"
  lipo -thin arm64 "$SRC_APP/Contents/Frameworks/libopenal.1.24.3.dylib" -output "$FW/libopenal.1.dylib"
  codesign --remove-signature "$FW/libopenal.1.dylib"
  install_name_tool -id @rpath/libopenal.1.dylib "$FW/libopenal.1.dylib" 2>/dev/null
  SDL_LIB="$DEPS/lib/libSDL3.0.dylib"
fi

echo "== shims"
SHIM=("${CC[@]}" -dynamiclib -fvisibility=hidden)
"${SHIM[@]}" -fno-objc-arc -I"$SDL_INC" -install_name @rpath/libShimCarbon.dylib \
  -o "$FW/libShimCarbon.dylib" "$HERE/shims/shim_carbon.m" \
  -framework Foundation -framework CoreFoundation -framework Metal "$SDL_LIB"
"${SHIM[@]}" -install_name @rpath/libShimCoreServices.dylib -o "$FW/libShimCoreServices.dylib" "$HERE/shims/shim_coreservices.c"
"${SHIM[@]}" -install_name @rpath/libShimApplicationServices.dylib -o "$FW/libShimApplicationServices.dylib" "$HERE/shims/shim_appservices.c"
"${SHIM[@]}" -install_name @rpath/libShimIOKit.dylib -o "$FW/libShimIOKit.dylib" "$HERE/shims/shim_iokit.c" -framework CoreFoundation

echo "== host"
HOST_SRC=("$HERE/host/host_common.c" "$HERE/host/stack_switch.S" "$HERE/host/objc_compat.m" "$HERE/host/stackdump.cpp" "$HERE/host/game_state.c" "$HERE/host/bc_decode.c")
[ -f "${DEVTOOLS:-}/autoinput.c" ] && HOST_SRC+=("$DEVTOOLS/autoinput.c")
if [ "$PLATFORM" = ios ]; then
  "${CC[@]}" -fno-objc-arc -I"$SDL_INC" -I"$HERE/host" -o "$APP/UT2004" "$HERE/host/ios/ios_main.m" \
    "$HERE/host/ios/touch_controls.m" "${HOST_SRC[@]}" \
    -framework UIKit -framework Foundation -framework Metal -framework QuartzCore -framework GameController -framework CoreGraphics -framework AVFoundation \
    "$SDL_LIB" -lc++ -Wl,-rpath,@executable_path/Frameworks
else
  "${CC[@]}" -fno-objc-arc -I"$SDL_INC" -I"$HERE/host" -o "$APP/UT2004" "$HERE/mac/host_mac.m" "${HOST_SRC[@]}" \
    -framework Foundation -framework Metal -framework QuartzCore "$SDL_LIB" -lc++ -Wl,-rpath,@executable_path/Frameworks
fi

echo "== game system files (from the patch)"
for d in System SystemLocalized Help Maps Sounds Textures Web; do
  [ -d "$SRC_APP/Contents/Resources/$d" ] && ditto "$SRC_APP/Contents/Resources/$d" "$APP/$d"
done
INI="$APP/System/Default.ini"
sed -i '' \
  -e 's/^RenderDevice=D3D9Drv\.D3D9RenderDevice/RenderDevice=MetalDrv.MetalRenderDevice/' \
  -e 's/^ViewportManager=WinDrv\.WindowsClient/ViewportManager=SDLDrv.SDLClient/' \
  -e '/^\[SDLDrv\.SDLClient\]/,/^\[/ s/^UseJoystick=False/UseJoystick=True/' \
  "$INI"
# Windowed: SDLDrv keeps bWindowsMouseAvailable set, so the GUI raises
# bShowWindowsMouse in menus and host/game_state.c can give menus an absolute
# pointer (fullscreen menus run on relative deltas only). On iOS the SDL
# window fills the screen either way.
perl -0pi -e 's/(\[SDLDrv\.SDLClient\][^\[]*?)StartupFullscreen=True/${1}StartupFullscreen=False/s' "$INI"
if [ "$PLATFORM" = macos ]; then
  perl -0pi -e 's/(\[SDLDrv\.SDLClient\][^\[]*?)WindowedViewportX=\d+/${1}WindowedViewportX=1280/s; s/(\[SDLDrv\.SDLClient\][^\[]*?)WindowedViewportY=\d+/${1}WindowedViewportY=720/s' "$INI"
fi
# Standard SDL mouse input: raw HID input does not exist on iOS, and with it
# selected SDLDrv stops at startup with an "Input Monitoring Required" dialog.
perl -0pi -e 's/^\[SDLDrv\.SDLClient\]\r?\n/[SDLDrv.SDLClient]\nMouseInputMode=SDL3_INPUT_Standard\n/m' "$INI"
grep -q '^RenderDevice=MetalDrv.MetalRenderDevice' "$INI" || { echo "Default.ini patch failed"; exit 1; }
grep -q '^MouseInputMode=SDL3_INPUT_Standard' "$INI" || { echo "Default.ini mouse patch failed"; exit 1; }
sed -n '/^\[SDLDrv\.SDLClient\]/,/^\[/p' "$INI" | grep -q '^StartupFullscreen=False' || { echo "Default.ini windowed patch failed"; exit 1; }

if [ "$PLATFORM" = macos ]; then
  # SDL 3.5 needs a bundle identifier on macOS (UNUserNotificationCenter
  # throws without one); same flat layout as iOS, so the plist sits at the root.
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID.mactest" \
    -c "Add :CFBundleExecutable string UT2004" -c "Add :CFBundleName string UT2004" \
    -c "Add :CFBundlePackageType string APPL" "$APP/Info.plist" >/dev/null
  for f in "$FW"/*.dylib "$APP/UT2004"; do codesign -f -s - "$f" >/dev/null; done
  rm -rf "$WORK"
  echo "built $APP"
  exit 0
fi

sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/" -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" \
  "$HERE/ios/Info.plist.in" > "$APP/Info.plist"
plutil -lint "$APP/Info.plist" >/dev/null

if [ -n "${ICON:-}" ]; then
  echo "== icon"
  XCA="$WORK/Assets.xcassets"
  mkdir -p "$XCA/AppIcon.appiconset"
  echo '{"info":{"version":1,"author":"xcode"}}' > "$XCA/Contents.json"
  # iOS icons must be opaque: flatten through JPEG, then back to PNG
  sips -s format jpeg -s formatOptions best -z 1024 1024 "$ICON" --out "$WORK/icon.jpg" >/dev/null
  sips -s format png "$WORK/icon.jpg" --out "$XCA/AppIcon.appiconset/icon.png" >/dev/null
  cat > "$XCA/AppIcon.appiconset/Contents.json" <<'JSON'
{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],
 "info":{"version":1,"author":"xcode"}}
JSON
  xcrun actool "$XCA" --compile "$APP" --platform iphoneos --minimum-deployment-target $MIN_OS \
    --target-device iphone --target-device ipad --app-icon AppIcon \
    --output-partial-info-plist "$WORK/icon.plist" >/dev/null
  /usr/libexec/PlistBuddy -c "Merge $WORK/icon.plist" "$APP/Info.plist" >/dev/null
fi

echo "== verify"
bad=0
for f in "$APP/UT2004" "$FW"/*.dylib; do
  plat=$(otool -l "$f" | awk '/LC_BUILD_VERSION/{p=1} p&&/platform/{print $2; exit}')
  [ "$plat" = 2 ] || { echo "not iOS: $f ($plat)"; bad=1; }
  if otool -L "$f" | tail -n +2 | grep -E 'Versions/|/System/Library/Frameworks/(OpenGL|AppKit|Cocoa|Carbon|IOKit|CoreServices|ApplicationServices)\.framework'; then
    echo "  ^ macOS dependency left in $f"; bad=1
  fi
done
[ $bad = 0 ] || exit 1
python3 -I "$HERE/tools/check_ios_imports.py" "$SDK" "$FW"/*.dylib "$APP/UT2004" | grep -v '^0 problem' && { echo "unresolved iOS imports"; exit 1; } || true

echo "== sign ($SIGN_ID)"
[ -n "${PROFILE:-}" ] && cp "$PROFILE" "$APP/embedded.mobileprovision"
for f in "$FW"/*.dylib; do codesign -f -s "$SIGN_ID" "$f" >/dev/null; done
codesign -f -s "$SIGN_ID" --entitlements "$HERE/ios/UT2004.entitlements" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
rm -rf "$WORK"

IPA="$OUT/UT2004-iOS-$VERSION-$BUILD.ipa"
rm -f "$IPA"
(cd "$OUT" && zip -qry "$(basename "$IPA")" Payload)
echo "built $IPA ($(du -h "$IPA" | cut -f1))"
