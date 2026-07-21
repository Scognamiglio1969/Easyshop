#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
else
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
fi
BUILD_DIR="$ROOT/.build"
WORK_DIR="$ROOT/work"
OUTPUT_DIR="$ROOT/outputs"
STAGE_ROOT="/private/tmp/easyshop-release-${UID}"
APP="$STAGE_ROOT/Easyshop.app"
ICON_SOURCE="$ROOT/Sources/EasyshopApp/Resources/AppIcon-1024.png"
ICONSET="$WORK_DIR/Easyshop.iconset"
ICON_FILE="$WORK_DIR/Easyshop.icns"

mkdir -p "$WORK_DIR/swift-cache" "$WORK_DIR/swift-config" "$WORK_DIR/swift-security" "$OUTPUT_DIR"

build_arch() {
    local arch="$1"
    local arch_build="$BUILD_DIR/$arch"
    env SDKROOT="$SDK" \
    CLANG_MODULE_CACHE_PATH="$BUILD_DIR/module-cache-$arch" \
    SWIFT_MODULECACHE_PATH="$BUILD_DIR/module-cache-$arch" \
    swift build -c release \
    --triple "${arch}-apple-macosx14.0" \
    --disable-sandbox \
    --scratch-path "$arch_build" \
    --cache-path "$WORK_DIR/swift-cache" \
    --config-path "$WORK_DIR/swift-config" \
    --security-path "$WORK_DIR/swift-security" \
    --manifest-cache local
}

build_arch arm64
build_arch x86_64

BIN_ARM="$BUILD_DIR/arm64/arm64-apple-macosx/release"
BIN_X86="$BUILD_DIR/x86_64/x86_64-apple-macosx/release"

rm -rf "$STAGE_ROOT" "$OUTPUT_DIR/Easyshop.app" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
lipo -create "$BIN_ARM/Easyshop" "$BIN_X86/Easyshop" -output "$APP/Contents/MacOS/Easyshop"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"

cp "$ROOT/Sources/EasyshopApp/Resources/DemoPortrait.png" "$APP/Contents/Resources/DemoPortrait.png"

if [[ ! -f "$ICON_FILE" || "$ICON_SOURCE" -nt "$ICON_FILE" ]]; then
    for SIZE in 16 32 128 256 512; do
        sips -z "$SIZE" "$SIZE" "$ICON_SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
        DOUBLE=$((SIZE * 2))
        sips -z "$DOUBLE" "$DOUBLE" "$ICON_SOURCE" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICON_FILE"
fi
cp "$ICON_FILE" "$APP/Contents/Resources/Easyshop.icns"

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
touch "$APP"

rm -f "$OUTPUT_DIR/Easyshop-0.1.0-alpha.dmg" "$OUTPUT_DIR/Easyshop-0.1.0-alpha.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT_DIR/Easyshop-0.1.0-alpha.zip"

DMG_ROOT="$STAGE_ROOT/dmg"
mkdir -p "$DMG_ROOT"
ditto --norsrc "$APP" "$DMG_ROOT/Easyshop.app"
xattr -cr "$DMG_ROOT/Easyshop.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "Easyshop 0.1 Alpha" -srcfolder "$DMG_ROOT" -ov -format UDZO "$OUTPUT_DIR/Easyshop-0.1.0-alpha.dmg" >/dev/null

# Keep a convenient local copy; DMG/ZIP are created from the clean staging bundle.
ditto --norsrc "$APP" "$OUTPUT_DIR/Easyshop.app"
xattr -cr "$OUTPUT_DIR/Easyshop.app"

echo "$APP"
echo "$OUTPUT_DIR/Easyshop-0.1.0-alpha.dmg"
