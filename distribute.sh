#!/bin/bash
# distribute.sh — builds, signs, packages, and releases TranscribeMeeting
set -e

APP_NAME="Whale"
SCHEME="TranscribeMeeting"
ENTITLEMENTS="Whale/TranscribeMeeting.entitlements"
DERIVED_DATA="build/xcode"
DIST_DIR="build/dist_staging"
DMG_NAME="${APP_NAME}.dmg"
GITHUB_REPO="sumitrk/whale-swift"

# ── Sparkle tools ────────────────────────────────────────────────────────────
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" \
  -path "*/artifacts/sparkle/*" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
if [ -z "$SPARKLE_BIN" ]; then
  echo "❌ Sparkle tools not found. Build the project in Xcode at least once first."
  exit 1
fi

# ── Version bump ─────────────────────────────────────────────────────────────
CURRENT_VERSION=$(defaults read "$(pwd)/Whale/Info.plist" CFBundleShortVersionString)
CURRENT_BUILD=$(defaults read "$(pwd)/Whale/Info.plist" CFBundleVersion)
NEXT_BUILD=$((CURRENT_BUILD + 1))

echo "Current version: ${CURRENT_VERSION} (build ${CURRENT_BUILD})"
read -rp "New version number (e.g. 0.4.0) [enter to keep ${CURRENT_VERSION}]: " INPUT_VERSION
VERSION="${INPUT_VERSION:-$CURRENT_VERSION}"
BUILD=$NEXT_BUILD

# Write back to Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "Whale/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "Whale/Info.plist"
echo "▶ Building version ${VERSION} (build ${BUILD})"

# ── PyInstaller binary check ─────────────────────────────────────────────────
echo ""
echo "▶ Checking PyInstaller binary..."
if [ ! -d "dist/transcribe_server" ]; then
  echo "❌ dist/transcribe_server not found."
  echo "   Run: source .venv/bin/activate && pyinstaller server.spec"
  exit 1
fi
echo "✅ PyInstaller binary found"

# ── Build ────────────────────────────────────────────────────────────────────
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
  clean build 2>&1 | grep -E "^(Build|error:)" || true

APP_PATH=$(find "$DERIVED_DATA" -name "${APP_NAME}.app" -maxdepth 6 | head -1)
if [ -z "$APP_PATH" ]; then
  echo "❌ Could not find ${APP_NAME}.app in DerivedData"
  exit 1
fi
echo "✅ Built: $APP_PATH"

# ── Bundle server binary ─────────────────────────────────────────────────────
echo ""
echo "▶ Bundling Python server binary..."
cp -r "dist/transcribe_server" "$APP_PATH/Contents/Resources/"
echo "✅ Server binary bundled"

# ── Ad-hoc sign ──────────────────────────────────────────────────────────────
echo ""
echo "▶ Ad-hoc signing..."
find "$APP_PATH/Contents" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) | while read f; do
  codesign --force --sign - "$f" 2>/dev/null || true
done
codesign --deep --force --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH"
echo "✅ Ad-hoc signed"

# ── Create DMG ───────────────────────────────────────────────────────────────
echo ""
echo "▶ Creating DMG..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -r "$APP_PATH" "$DIST_DIR/"
ln -s /Applications "$DIST_DIR/Applications"
rm -f "$DMG_NAME"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DIST_DIR" \
  -ov -format UDZO \
  "$DMG_NAME" 2>&1 | tail -2
rm -rf "$DIST_DIR"
echo "✅ Created ${DMG_NAME}"

# ── Sign DMG for Sparkle ─────────────────────────────────────────────────────
echo ""
echo "▶ Signing DMG for Sparkle..."
SIGN_OUTPUT=$("$SPARKLE_BIN/sign_update" "$DMG_NAME")
ED_SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
DMG_LENGTH=$(echo "$SIGN_OUTPUT" | grep -o 'length="[^"]*"' | cut -d'"' -f2)
if [ -z "$ED_SIGNATURE" ]; then
  echo "❌ Failed to sign DMG. Is the private key in your keychain?"
  exit 1
fi
echo "✅ DMG signed (length: ${DMG_LENGTH} bytes)"

# ── Update appcast.xml ───────────────────────────────────────────────────────
echo ""
echo "▶ Updating appcast.xml..."
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
DMG_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/${DMG_NAME}"

cat > appcast.xml << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Whale Updates</title>
        <link>https://github.com/${GITHUB_REPO}</link>
        <description>Most recent changes with links to updates.</description>
        <language>en</language>
        <item>
            <title>Version ${VERSION}</title>
            <sparkle:version>${BUILD}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <pubDate>${PUB_DATE}</pubDate>
            <enclosure
                url="${DMG_URL}"
                sparkle:edSignature="${ED_SIGNATURE}"
                length="${DMG_LENGTH}"
                type="application/octet-stream"
            />
        </item>
    </channel>
</rss>
EOF
echo "✅ appcast.xml updated"

# ── GitHub release ───────────────────────────────────────────────────────────
echo ""
echo "▶ Creating GitHub release v${VERSION}..."
if ! command -v gh &>/dev/null; then
  echo "⚠️  gh CLI not found — skipping GitHub release."
  echo "   Install with: brew install gh"
  echo "   Then manually upload ${DMG_NAME} to https://github.com/${GITHUB_REPO}/releases"
else
  gh release create "v${VERSION}" "$DMG_NAME" \
    --repo "$GITHUB_REPO" \
    --title "v${VERSION}" \
    --notes "Whale v${VERSION}" \
    2>&1 && echo "✅ GitHub release created" || echo "⚠️  Release may already exist — upload DMG manually"
fi

# ── Commit and push appcast.xml ──────────────────────────────────────────────
echo ""
echo "▶ Pushing appcast.xml to main..."
git add appcast.xml
git commit -m "release: v${VERSION}" || echo "(appcast.xml unchanged)"
git push origin main
echo "✅ appcast.xml live"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Released v${VERSION}"
echo "   DMG     → $(pwd)/${DMG_NAME}"
echo "   Appcast → https://raw.githubusercontent.com/${GITHUB_REPO}/main/appcast.xml"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Existing users will be notified automatically on next app launch."
