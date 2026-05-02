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
VERSION="0.1.0"
BUILD="$(git -C "$ROOT" rev-parse --short HEAD)"

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

echo "==> copying SPM resource bundle (rp.ico etc.)"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/MacOS/"
fi

echo "==> copying vendored libmpv dylibs"
cp "$ROOT"/Vendor/libmpv/lib/*.dylib "$APP_DIR/Contents/Frameworks/"

echo "==> adding @loader_path/../Frameworks rpath to binary"
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_DIR/Contents/MacOS/$APP_NAME" 2>/dev/null || true

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

echo "==> ad-hoc codesign (silences Gatekeeper translocation; keeps unsigned)"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo
echo "Built: $APP_DIR"
echo "Run:   open \"$APP_DIR\""
echo
echo "First launch: macOS may show 'unidentified developer' warning."
echo "Bypass:       right-click the .app in Finder, choose Open."
echo "Or:           xattr -dr com.apple.quarantine \"$APP_DIR\""
