#!/bin/bash
# distribute.sh — builds, ad-hoc signs, and packages TranscribeMeeting into a DMG
set -e

APP_NAME="TranscribeMeeting"
SCHEME="TranscribeMeeting"
ENTITLEMENTS="TranscribeMeeting/TranscribeMeeting.entitlements"
DERIVED_DATA="build/xcode"
DIST_DIR="build/dist_staging"
DMG_NAME="${APP_NAME}.dmg"

echo "▶ Checking PyInstaller binary..."
if [ ! -d "dist/transcribe_server" ]; then
  echo "❌ dist/transcribe_server not found."
  echo "   Run this first: source .venv/bin/activate && pyinstaller server.spec"
  exit 1
fi
echo "✅ PyInstaller binary found"

echo ""
echo "▶ Building Xcode project (Release, ad-hoc signed)..."
xcodebuild \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  OTHER_CODE_SIGN_FLAGS="" \
  clean build 2>&1 | grep -E "^(Build|error:|CompileSwift|Ld )" || true

# Find the built .app
APP_PATH=$(find "$DERIVED_DATA" -name "${APP_NAME}.app" -maxdepth 6 | head -1)
if [ -z "$APP_PATH" ]; then
  echo "❌ Could not find ${APP_NAME}.app in DerivedData"
  exit 1
fi
echo "✅ Built: $APP_PATH"

echo ""
echo "▶ Bundling Python server binary..."
cp -r "dist/transcribe_server" "$APP_PATH/Contents/Resources/"
echo "✅ Server binary bundled"

echo ""
echo "▶ Ad-hoc signing app and all nested binaries..."
# Sign nested binaries first (frameworks, dylibs, executables inside Resources)
find "$APP_PATH/Contents" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) | while read f; do
  codesign --force --sign - "$f" 2>/dev/null || true
done
# Sign the .app itself with entitlements
codesign --deep --force --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH"
echo "✅ Ad-hoc signed"

echo ""
echo "▶ Verifying signature..."
codesign --verify --verbose "$APP_PATH" && echo "✅ Signature valid" || echo "⚠️  Signature issue (may still work)"

echo ""
echo "▶ Creating DMG..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -r "$APP_PATH" "$DIST_DIR/"
# Add Applications symlink so users can drag-install
ln -s /Applications "$DIST_DIR/Applications"

rm -f "$DMG_NAME"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DIST_DIR" \
  -ov \
  -format UDZO \
  "$DMG_NAME" 2>&1 | tail -3

rm -rf "$DIST_DIR"
echo ""
echo "✅ Done! → $(pwd)/${DMG_NAME}"
echo ""
echo "Share ${DMG_NAME} with friends."
echo "They should: open DMG → drag app to Applications → right-click → Open (first time only)"
