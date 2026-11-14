#!/bin/bash
# Build the libraries that replace OldUnreal's macOS SDL3 / OpenAL Soft.
#   PLATFORM=ios   : libSDL3.0.dylib (+ UT2004 input extension) and libopenal.1.dylib for iOS
#   PLATFORM=macos : libSDL3.0.dylib (+ extension) for the macOS test build
# usage: build_deps.sh <SDL3 source> <openal-soft source> <out dir>
# Low load on purpose: 2 jobs, nice 19. SKIP_OPENAL=1 keeps the existing OpenAL.
set -euo pipefail
SDL_SRC=$(cd "${1:?SDL3 source dir}" && pwd)
AL_SRC=${2:?openal-soft source dir}
OUT=${3:?output dir}
HERE=$(cd "$(dirname "$0")/.." && pwd)
PLATFORM=${PLATFORM:-ios}
JOBS=${JOBS:-2}
mkdir -p "$OUT/lib" "$OUT/include"

case "$PLATFORM" in
  ios)   MIN=16.0; SDKNAME=iphoneos; VERFLAG=-miphoneos-version-min=$MIN
         SYS=(-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos) ;;
  macos) MIN=11.0; SDKNAME=macosx; VERFLAG=-mmacosx-version-min=$MIN
         SYS=(-DCMAKE_OSX_SYSROOT=macosx) ;;
  *) echo "PLATFORM must be ios or macos"; exit 1 ;;
esac
SDK=$(xcrun --sdk $SDKNAME --show-sdk-path)
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release "${SYS[@]}" -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN")
CC=(xcrun --sdk $SDKNAME clang -arch arm64 -isysroot "$SDK" $VERFLAG -O2)

# ---- SDL3 (static) + UT2004 extension -> libSDL3.0.dylib -------------------
cmake -S "$SDL_SRC" -B "$OUT/sdl3-static" "${COMMON[@]}" \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF \
  -DSDL_INSTALL=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
nice -n 19 cmake --build "$OUT/sdl3-static" -j "$JOBS"

"${CC[@]}" -fPIC -DUSING_GENERATED_CONFIG_H \
  -I"$OUT/sdl3-static/include-config-release" -I"$OUT/sdl3-static/include-config-release/build_config" \
  -I"$OUT/sdl3-static/include" -I"$SDL_SRC/include" -I"$SDL_SRC/src" -I"$HERE/sdl_ext" \
  -c "$HERE/sdl_ext/SDL_ut2004.c" -o "$OUT/sdl3-static/SDL_ut2004.o"

# frameworks/libs SDL needs, from its own pkg-config file
# system libraries SDL needs (iOS list = SDL's own shared-library link line)
if [ "$PLATFORM" = ios ]; then
  FW_LIST=(AudioToolbox AVFoundation CoreAudio CoreGraphics CoreMedia CoreMotion CoreVideo
           Foundation Metal OpenGLES QuartzCore Security UIKit)
  WEAK_LIST=(CoreBluetooth CoreHaptics GameController UserNotifications)
else
  FW_LIST=(Cocoa Carbon IOKit ForceFeedback CoreAudio AudioToolbox AVFoundation CoreVideo CoreMedia
           Metal QuartzCore UniformTypeIdentifiers Foundation CoreFoundation CoreGraphics Security)
  WEAK_LIST=(CoreHaptics GameController UserNotifications)
fi
PRIV="-lm"
for f in "${FW_LIST[@]}"; do PRIV+=" -framework $f"; done
for f in "${WEAK_LIST[@]}"; do PRIV+=" -weak_framework $f"; done
EXPORTS="$OUT/sdl3-static/exports.txt"
grep '^_' "$SDL_SRC/src/dynapi/SDL_dynapi.exports" > "$EXPORTS"
grep -oE 'SDL_UT_[A-Za-z]+' "$HERE/sdl_ext/SDL_ut2004.h" | sort -u | sed 's/^/_/' >> "$EXPORTS"
EXTRA=$(find "$OUT/sdl3-static" -maxdepth 1 -name 'libSDL_uclibc.a' | head -1)
# shellcheck disable=SC2086
"${CC[@]}" -dynamiclib -o "$OUT/lib/libSDL3.0.dylib" \
  -install_name @rpath/libSDL3.0.dylib -compatibility_version 501.0.0 -current_version 501.0.0 \
  -Wl,-headerpad_max_install_names -Wl,-exported_symbols_list,"$EXPORTS" \
  -Wl,-all_load "$OUT/sdl3-static/libSDL3.a" ${EXTRA:+"$EXTRA"} "$OUT/sdl3-static/SDL_ut2004.o" \
  $PRIV
rm -rf "$OUT/include/SDL3"
cp -R "$SDL_SRC/include/SDL3" "$OUT/include/SDL3"
cp "$HERE/sdl_ext/SDL_ut2004.h" "$OUT/include/SDL3/SDL_ut2004.h"
nm -gU "$OUT/lib/libSDL3.0.dylib" | grep -c ' _SDL_' | xargs echo "SDL exports:"
nm -gU "$OUT/lib/libSDL3.0.dylib" | grep '_SDL_UT_' | awk '{print $3}' | tr '\n' ' '; echo

# ---- OpenAL Soft (iOS only; the macOS test keeps OldUnreal's) -----------------
if [ "$PLATFORM" = ios ] && [ -z "${SKIP_OPENAL:-}" ]; then
  cmake -S "$AL_SRC" -B "$OUT/openal" "${COMMON[@]}" \
    -DHAVE_WFUNCTION_EFFECTS=OFF \
    -DLIBTYPE=SHARED -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
    -DALSOFT_INSTALL=OFF -DALSOFT_INSTALL_CONFIG=OFF -DALSOFT_INSTALL_HRTF_DATA=OFF \
    -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF -DALSOFT_EMBED_HRTF_DATA=ON
  nice -n 19 cmake --build "$OUT/openal" -j "$JOBS"
  AL=$(find "$OUT/openal" -maxdepth 1 -name 'libopenal.*.dylib' -type f | head -1)
  cp -f "$AL" "$OUT/lib/libopenal.1.dylib"
  install_name_tool -id @rpath/libopenal.1.dylib "$OUT/lib/libopenal.1.dylib"
fi

for f in "$OUT"/lib/*.dylib; do
  echo "$f: platform $(otool -l "$f" | awk '/LC_BUILD_VERSION/{p=1} p&&/platform/{print $2; exit}')"
done
