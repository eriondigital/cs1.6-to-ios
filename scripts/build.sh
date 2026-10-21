#!/usr/bin/env bash
#
# Builds Counter-Strike 1.6 for iOS on macOS (GitHub Actions runner or a Mac with Xcode).
#
#   scripts/build.sh device      -> out/device/CS16-iOS.ipa            (iPhone / iPad)
#   scripts/build.sh simulator   -> out/simulator/Payload/CS16.app     (iOS Simulator)
#
# Expects the upstream sources next to this repo's files (the workflow checks them out):
#   xash3d-fwgs/   https://github.com/FWGS/xash3d-fwgs   (engine)
#   cs16-client/   https://github.com/Velaron/cs16-client (client, menu, ReGameDLL_CS, YaPB)
#
set -euo pipefail

TARGET="${1:-device}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XASH="${XASH_DIR:-$ROOT/xash3d-fwgs}"
CS16="${CS16_DIR:-$ROOT/cs16-client}"
SDL_VERSION="${SDL_VERSION:-2.32.10}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DEPS="$ROOT/deps"
OUT="$ROOT/out/$TARGET"
APP="$OUT/Payload/CS16.app"
JOBS="$(sysctl -n hw.ncpu)"
MIN_IOS=14.0

case "$TARGET" in
	device)    SDK=iphoneos;        WAF_TARGET=--ios;           SDL_SLICE=ios-arm64;                  PLATFORM_NAME=iPhoneOS ;;
	simulator) SDK=iphonesimulator; WAF_TARGET=--ios-simulator; SDL_SLICE=ios-arm64_x86_64-simulator; PLATFORM_NAME=iPhoneSimulator ;;
	*) echo "usage: $0 device|simulator" >&2; exit 1 ;;
esac

log() { printf '\n==> %s\n' "$*"; }

log "Toolchain"
xcodebuild -version
xcrun --sdk "$SDK" --show-sdk-path

# ---------------------------------------------------------------- SDL2
if [ ! -d "$DEPS/SDL2.xcframework/$SDL_SLICE/SDL2.framework" ]; then
	log "Building SDL $SDL_VERSION (xcframework)"
	rm -rf "$DEPS/SDL-src" "$DEPS/SDL2.xcframework"
	mkdir -p "$DEPS"
	git clone --depth 1 -b "release-$SDL_VERSION" https://github.com/libsdl-org/SDL "$DEPS/SDL-src"
	( cd "$DEPS/SDL-src/Xcode/SDL" && xcodebuild -scheme xcFramework-iOS -target xcFramework-iOS build -configuration Release )
	cp -R "$DEPS/SDL-src/Xcode/SDL/Products/SDL2.xcframework" "$DEPS/"
fi
SDL_FW="$DEPS/SDL2.xcframework/$SDL_SLICE/SDL2.framework"
ls "$DEPS/SDL2.xcframework"
test -d "$SDL_FW"

# ---------------------------------------------------------------- patches
log "Applying iOS port changes"
python3 "$ROOT/scripts/apply_patches.py" "$XASH" "$CS16" "$ROOT"

rm -rf "$OUT"
mkdir -p "$APP"

# ---------------------------------------------------------------- engine
log "Building Xash3D FWGS engine ($TARGET)"
(
	cd "$XASH"
	./waf configure --enable-lto "$WAF_TARGET" --sdl2="$SDL_FW" -o "build-$TARGET"
	./waf build -j "$JOBS"
	./waf install --destdir="$APP"
)

# ---------------------------------------------------------------- cs16-client
log "Building cs16-client: client, menu, ReGameDLL_CS, YaPB ($TARGET)"
cmake -S "$CS16" -B "$OUT/cs16-build" -G "Unix Makefiles" \
	-DCMAKE_SYSTEM_NAME=iOS \
	-DCMAKE_OSX_SYSROOT="$SDK" \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
	-DCMAKE_BUILD_TYPE=Release \
	-DXASH_COMPAT=ON \
	-DMAINUI_USE_STB=ON \
	-DCMAKE_INSTALL_PREFIX="$OUT/cs16-install"
cmake --build "$OUT/cs16-build" --parallel "$JOBS"
cmake --install "$OUT/cs16-build"

# ---------------------------------------------------------------- bundle
log "Assembling CS16.app"

# The engine names game libraries <name>_ios_arm64.dylib on iOS, cs16-client's CMake
# names them <name>_arm64.dylib (it doesn't know about iOS). YaPB looks the CS server
# library up by its own rule (cs_arm64.dylib), so that one keeps its name as well.
CS_OUT="$OUT/cs16-install/cstrike"
mkdir -p "$APP/cstrike/cl_dlls" "$APP/cstrike/dlls"
cp "$CS_OUT/cl_dlls/client_arm64.dylib" "$APP/cstrike/cl_dlls/client_ios_arm64.dylib"
cp "$CS_OUT/cl_dlls/menu_arm64.dylib"   "$APP/cstrike/cl_dlls/menu_ios_arm64.dylib"
cp "$CS_OUT/dlls/yapb_arm64.dylib"      "$APP/cstrike/dlls/yapb_ios_arm64.dylib"
cp "$CS_OUT/dlls/cs_arm64.dylib"        "$APP/cstrike/dlls/cs_arm64.dylib"
cp "$CS_OUT/dlls/cs_arm64.dylib"        "$APP/cstrike/dlls/cs_ios_arm64.dylib" # used when started without bots (-dll @cs)
python3 "$ROOT/scripts/repack_extras.py" "$CS_OUT/extras.pk3" "$APP/cstrike/extras.pk3"

# SDL2 sits next to the executable, which links it through @rpath = @loader_path
cp -R "$SDL_FW" "$APP/SDL2.framework"
rm -rf "$APP/SDL2.framework/Headers" "$APP/SDL2.framework/PrivateHeaders" "$APP/SDL2.framework/Modules"

# Info.plist, icons
cp "$ROOT/ios/Info.plist" "$APP/Info.plist"
cp "$ROOT"/ios/icons/*.png "$APP/"
PB=/usr/libexec/PlistBuddy
SDK_VER="$(xcrun --sdk "$SDK" --show-sdk-version)"
SDK_BUILD="$(xcrun --sdk "$SDK" --show-sdk-build-version)"
XCODE_VER="$(xcodebuild -version | awk '/Xcode/{print $2}')"
XCODE_BUILD="$(xcodebuild -version | awk '/Build version/{print $3}')"
$PB -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Info.plist"
$PB -c "Set :CFBundleShortVersionString 1.0.$BUILD_NUMBER" "$APP/Info.plist"
$PB -c "Set :CFBundleSupportedPlatforms:0 $PLATFORM_NAME" "$APP/Info.plist"
$PB -c "Set :MinimumOSVersion $MIN_IOS" "$APP/Info.plist"
$PB -c "Add :DTPlatformName string $SDK" "$APP/Info.plist"
$PB -c "Add :DTPlatformVersion string $SDK_VER" "$APP/Info.plist"
$PB -c "Add :DTSDKName string $SDK$SDK_VER" "$APP/Info.plist"
$PB -c "Add :DTSDKBuild string $SDK_BUILD" "$APP/Info.plist"
$PB -c "Add :DTPlatformBuild string $SDK_BUILD" "$APP/Info.plist"
$PB -c "Add :DTXcode string $(echo "$XCODE_VER" | awk -F. '{printf "%d%d%d", $1, $2, ($3==""?0:$3)}')" "$APP/Info.plist"
$PB -c "Add :DTXcodeBuild string $XCODE_BUILD" "$APP/Info.plist"
$PB -c "Add :DTCompiler string com.apple.compilers.llvm.clang.1_0" "$APP/Info.plist"
$PB -c "Add :BuildMachineOSBuild string $(sw_vers -buildVersion)" "$APP/Info.plist"

# compiled asset catalog for current iOS versions; the loose PNGs above are the fallback
if xcrun actool "$ROOT/ios/Assets.xcassets" --compile "$APP" --platform "$SDK" \
	--minimum-deployment-target "$MIN_IOS" --app-icon AppIcon \
	--target-device iphone --target-device ipad \
	--output-partial-info-plist "$OUT/actool-info.plist" \
	--output-format human-readable-text; then
	$PB -c "Merge $OUT/actool-info.plist" "$APP/Info.plist" || true
else
	echo "warning: actool failed, the app will use the PNG icons"
fi
plutil -lint "$APP/Info.plist"

# ---------------------------------------------------------------- checks
log "Checking bundle"
python3 "$ROOT/scripts/verify_bundle.py" "$APP"

# ---------------------------------------------------------------- signing
# Ad-hoc signature only. Sideloadly / AltStore / TrollStore re-sign the app
# with the user's own certificate when installing.
log "Ad-hoc signing"
find "$APP" -type f -name '*.dylib' -print0 | xargs -0 -n1 codesign --force --sign - --timestamp=none
codesign --force --sign - --timestamp=none "$APP/SDL2.framework"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP" || echo "warning: codesign --verify complained"

log "Bundle contents"
( cd "$APP" && find . -type f | sort | sed 's/^/  /' | head -200 )
du -sh "$APP"

if [ "$TARGET" = device ]; then
	log "Packaging IPA"
	( cd "$OUT" && rm -f CS16-iOS.ipa && zip -qry CS16-iOS.ipa Payload )
	ls -la "$OUT/CS16-iOS.ipa"
fi

log "Done: $TARGET"
