#!/usr/bin/env bash
# Local-only .app wrapper for testing notifications and other bundled-process
# behavior. Unsigned, ad-hoc, throwaway. PR 13 will replace this with a proper
# CI-built artifact.
#
# Usage: ./scripts/make-app.sh [debug|release]   (default: release)

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="RP Player"
APP_DIR="$ROOT/build/$APP_NAME.app"
BUNDLE_ID="com.gvajda.rpplayer"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git -C "$ROOT" rev-parse --short HEAD)"
ENTITLEMENTS="$ROOT/scripts/entitlements.plist"
ICON_SRC="$ROOT/Sources/RPPlayer/Resources/rp.ico"

echo "==> swift build -c $CONFIG"
swift build --package-path "$ROOT" -c "$CONFIG"

BIN_DIR="$ROOT/.build/$CONFIG"
BIN="$BIN_DIR/RPPlayer"
RESOURCE_BUNDLE="$BIN_DIR/RPPlayer_RPPlayer.bundle"

if [[ ! -x "$BIN" ]]; then
    echo "ERROR: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> wiping old $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"

echo "==> copying binary"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

echo "==> copying SPM resource bundle (rp.ico etc.) to Contents/Resources"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
fi

echo "==> copying vendored libmpv dylibs"
cp "$ROOT"/Vendor/libmpv/lib/*.dylib "$APP_DIR/Contents/Frameworks/"

echo "==> adding @loader_path/../Frameworks rpath to binary"
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "==> generating AppIcon.icns from rp.ico"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
TMP_PNG="$(mktemp -d)/rp.png"
sips -s format png "$ICON_SRC" --out "$TMP_PNG" >/dev/null
for size in 16 32 64 128 256 512; do
    double=$((size * 2))
    sips -z $size $size "$TMP_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $double $double "$TMP_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 1024 1024 "$TMP_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> writing Info.plist"
cat >"$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> codesign"
# Pick a stable signing identity if available, else ad-hoc.
# UNUserNotificationCenter requires a stable identity (not ad-hoc `-`) for
# usernoted to register the bundle and prompt the user for permission.
# Create a self-signed cert once (see scripts/README.md) — script auto-picks it.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    # Preference order: explicit RP Player Dev → Developer ID Application →
    # Apple Development → Apple Distribution → ad-hoc fallback.
    for pattern in "RP Player Dev" "Developer ID Application" "Apple Development" "Apple Distribution"; do
        match="$(echo "$IDENTITIES" | grep -m1 "\"$pattern" | sed -E 's/.*"([^"]+)".*/\1/' || true)"
        if [[ -n "$match" ]]; then
            SIGN_IDENTITY="$match"
            break
        fi
    done
    if [[ -z "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="-"
        echo "    (no signing identity found, using ad-hoc — notifications will NOT prompt)"
    fi
fi
echo "    using identity: $SIGN_IDENTITY"

# Hardened runtime + library validation disabled. Without disable-library-
# validation, the hardened-runtime exe rejects dylibs whose signing identity
# differs from the main executable.
for dylib in "$APP_DIR"/Contents/Frameworks/*.dylib; do
    codesign --force --sign "$SIGN_IDENTITY" "$dylib"
done
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP_DIR"

echo
echo "Built: $APP_DIR"
echo "Run:   open \"$APP_DIR\""
echo
echo "First launch: macOS may show 'unidentified developer' warning."
echo "Bypass:       right-click the .app in Finder, choose Open."
echo "Or:           xattr -dr com.apple.quarantine \"$APP_DIR\""
