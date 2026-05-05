#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="WindowPin"
SIGN_ID="${SIGN_ID:-Developer ID Application: Jonthan Hollin (EG86BCGUE7)}"
BUILD_DIR="$SCRIPT_DIR/.build/release"
APP_BUNDLE="$SCRIPT_DIR/_BuildOutput/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

# `import Sparkle` triggers Swift auto-link, which contributes the
# -framework directive. We just need to give swiftc + ld the framework
# search path (compile + link time) and the runtime rpath.
echo "==> Building ${APP_NAME}..."
swift build -c release \
    -Xswiftc -F -Xswiftc "$SCRIPT_DIR" \
    -Xlinker -F -Xlinker "$SCRIPT_DIR" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    2>&1

echo "==> Assembling ${APP_NAME}.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

cp "$BUILD_DIR/$APP_NAME" "$MACOS/$APP_NAME"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"

echo "==> Embedding Sparkle.framework..."
cp -R "$SCRIPT_DIR/Sparkle.framework" "$FRAMEWORKS/"

echo "==> Signing nested Sparkle code (leaves first)..."
SP="$FRAMEWORKS/Sparkle.framework/Versions/B"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$SP/XPCServices/Downloader.xpc"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$SP/XPCServices/Installer.xpc"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$SP/Updater.app"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$SP/Autoupdate"
codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$FRAMEWORKS/Sparkle.framework"

echo "==> Signing ${APP_NAME}.app..."
xattr -cr "$APP_BUNDLE"
codesign --force --sign "$SIGN_ID" --entitlements "$SCRIPT_DIR/${APP_NAME}.entitlements" --options runtime --timestamp "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
