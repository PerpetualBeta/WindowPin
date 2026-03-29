#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="WindowPin"
BUILD_DIR="$SCRIPT_DIR/.build/release"
APP_BUNDLE="$SCRIPT_DIR/_BuildOutput/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building ${APP_NAME}..."
swift build -c release 2>&1

echo "==> Assembling ${APP_NAME}.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>WindowPin</string>
    <key>CFBundleIdentifier</key>
    <string>com.jorvik.WindowPin</string>
    <key>CFBundleName</key>
    <string>WindowPin</string>
    <key>CFBundleDisplayName</key>
    <string>WindowPin</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "==> Code signing..."
xattr -cr "$APP_BUNDLE"
codesign --force --sign A74F91AE01AD39816B37E04FA1C764CA5F284577 "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
