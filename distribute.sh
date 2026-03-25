#!/bin/bash
# distribute.sh — deterministic packaging pipeline for Whale.
# The checked-in Whale.xcodeproj is the canonical build/signing source of truth.
#
# Default mode is publish for bridge distribution:
# - builds the app
# - injects the prepared transcribe_server artifact
# - re-signs only the injected payload + top-level app
# - verifies bundle integrity
# - creates a DMG
#
# On main, publish mode also creates the GitHub release and pushes release
# metadata to main. On other branches, publish mode behaves like a branch
# preview: it signs the DMG, updates appcast.xml, and pushes the current branch
# without creating a repo-wide GitHub release.
#
# Optional local-only dry run:
#   WHALE_RELEASE_MODE=local ./distribute.sh
# Public "download and just open" distribution still requires Developer ID +
# notarization, which this repo does not currently support.
set -euo pipefail

APP_NAME="Whale"
SCHEME="Whale"
ENTITLEMENTS="Whale/TranscribeMeeting.entitlements"
DERIVED_DATA="build/xcode"
DIST_DIR="build/dist_staging"
DMG_NAME="${APP_NAME}.dmg"
GITHUB_REPO="sumitrk/whale-app"
RELEASE_MODE="${WHALE_RELEASE_MODE:-publish}"
RUN_SMOKE_TEST="${WHALE_SMOKE_TEST:-0}"
CURRENT_BRANCH="$(git branch --show-current)"

if [ "$RELEASE_MODE" != "local" ] && [ "$RELEASE_MODE" != "publish" ]; then
  echo "❌ Unsupported WHALE_RELEASE_MODE: $RELEASE_MODE"
  echo "   Use WHALE_RELEASE_MODE=local or WHALE_RELEASE_MODE=publish"
  exit 1
fi

VERSION_PLIST="Whale/Info.plist"
APP_PATH=""
SIGNING_IDENTITY=""
VERSION=""
BUILD=""
SPARKLE_BIN=""
ED_SIGNATURE=""
DMG_LENGTH=""
DMG_URL=""

require_server_bundle() {
  echo ""
  echo "▶ Checking bundled transcription server..."
  if [ ! -d "dist/transcribe_server" ]; then
    echo "❌ dist/transcribe_server not found."
    echo "   Run: ./scripts/build_server_binary.sh"
    exit 1
  fi
  echo "✅ Server bundle found"
}

resolve_sparkle_tools() {
  SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" \
    -path "*/artifacts/sparkle/*" 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
  if [ -z "$SPARKLE_BIN" ]; then
    echo "❌ Sparkle tools not found. Build the project in Xcode at least once first."
    exit 1
  fi
}

sync_version_metadata() {
  local current_version current_build next_build input_version
  current_version=$(defaults read "$(pwd)/${VERSION_PLIST}" CFBundleShortVersionString)
  current_build=$(defaults read "$(pwd)/${VERSION_PLIST}" CFBundleVersion)
  next_build=$((current_build + 1))

  if [ "$RELEASE_MODE" = "publish" ]; then
    echo "Current version: ${current_version} (build ${current_build})"
    read -rp "New version number (e.g. 0.4.0) [enter to keep ${current_version}]: " input_version
    VERSION="${input_version:-$current_version}"
    BUILD="$next_build"

    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$VERSION_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "$VERSION_PLIST"
    echo "▶ Building version ${VERSION} (build ${BUILD})"
  else
    VERSION="$current_version"
    BUILD="$current_build"
    echo "▶ Packaging current version ${VERSION} (build ${BUILD})"
  fi
}

build_app() {
  local ws_state project_dir

  ws_state="${DERIVED_DATA}/SourcePackages/workspace-state.json"
  if [ -f "$ws_state" ]; then
    project_dir="$(pwd)"
    sed -i '' "s|\"path\" : \"[^\"]*/${DERIVED_DATA}/|\"path\" : \"${project_dir}/${DERIVED_DATA}/|g" "$ws_state" 2>/dev/null || true
  fi

  echo ""
  echo "▶ Building Xcode project (Release, Xcode-signed)..."
  xcodebuild \
    -project Whale.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    clean build 2>&1 | grep -E "^(Build|error:)" || true

  APP_PATH=$(find "$DERIVED_DATA" -name "${APP_NAME}.app" -maxdepth 6 | head -1)
  if [ -z "$APP_PATH" ]; then
    echo "❌ Could not find ${APP_NAME}.app in DerivedData"
    exit 1
  fi
  echo "✅ Built: $APP_PATH"
}

bundle_server_payload() {
  local internal_dir metallib_link metallib_target

  echo ""
  echo "▶ Bundling Python server binary..."
  cp -r "dist/transcribe_server" "$APP_PATH/Contents/Resources/"
  internal_dir="$APP_PATH/Contents/Resources/transcribe_server/_internal"
  metallib_link="$internal_dir/mlx.metallib"
  metallib_target="mlx/lib/mlx.metallib"
  if [ -f "$internal_dir/$metallib_target" ] && [ ! -e "$metallib_link" ]; then
    ln -s "$metallib_target" "$metallib_link"
  fi
  echo "✅ Server binary bundled"
}

resign_app() {
  local server_dest app_codesign_details

  echo ""
  echo "▶ Re-signing bundled server with the app's real identity..."

  app_codesign_details=$(codesign -dvvv "$APP_PATH" 2>&1)
  SIGNING_IDENTITY=$(printf "%s\n" "$app_codesign_details" | awk -F= '/^Authority=/{print $2; exit}')
  if [ -z "$SIGNING_IDENTITY" ]; then
    echo "❌ Could not determine the app signing identity."
    echo "   The release app must be signed by Xcode with a real certificate."
    exit 1
  fi

  server_dest="$APP_PATH/Contents/Resources/transcribe_server"

  find "$server_dest" -type f \( -name "*.dylib" -o -name "*.so" -o -perm -111 \) -print0 | \
  while IFS= read -r -d '' f; do
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$f"
  done

  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --preserve-metadata=identifier,requirements,flags \
    --timestamp=none \
    "$APP_PATH"

  if codesign -dvvv "$APP_PATH" 2>&1 | grep -q "Signature=adhoc"; then
    echo "❌ Release app is still ad-hoc signed; aborting packaging."
    exit 1
  fi

  echo "✅ Re-signed with ${SIGNING_IDENTITY}"
}

verify_app_bundle() {
  local smoke_root smoke_app app_codesign_details app_requirement

  echo ""
  echo "▶ Verifying app bundle..."
  codesign --verify --deep --strict --verbose=4 "$APP_PATH"
  app_codesign_details=$(codesign -dvvv "$APP_PATH" 2>&1)
  printf "%s\n" "$app_codesign_details" | tail -3
  app_requirement=$(codesign -dr - "$APP_PATH" 2>&1)
  printf "%s\n" "$app_requirement" | tail -1

  echo ""
  echo "▶ Gatekeeper check on app bundle (informational for bridge distribution)..."
  if spctl -a -vvv "$APP_PATH"; then
    echo "✅ App accepted by spctl"
  else
    echo "ℹ️  App not accepted by Gatekeeper. This is expected with Apple Development signing."
    echo "   Manual install may require right-click Open or quarantine removal on tester Macs."
  fi

  if [ "$RUN_SMOKE_TEST" = "1" ]; then
    echo ""
    echo "▶ Running post-launch integrity smoke test..."
    smoke_root="${DERIVED_DATA}/smoke"
    rm -rf "$smoke_root"
    mkdir -p "$smoke_root"
    ditto "$APP_PATH" "$smoke_root/${APP_NAME}.app"
    smoke_app="$smoke_root/${APP_NAME}.app"
    open "$smoke_app"
    sleep 5
    codesign --verify --deep --strict --verbose=4 "$smoke_app"
    pkill -f "${smoke_app}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    echo "✅ Post-launch integrity check passed"
  fi
}

create_dmg() {
  echo ""
  echo "▶ Creating DMG..."
  rm -rf "$DIST_DIR"
  mkdir -p "$DIST_DIR"
  # Preserve framework symlinks exactly; cp -r can flatten Sparkle.framework.
  ditto "$APP_PATH" "$DIST_DIR/${APP_NAME}.app"
  ln -s /Applications "$DIST_DIR/Applications"
  rm -f "$DMG_NAME"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DIST_DIR" \
    -ov -format UDZO \
    "$DMG_NAME" 2>&1 | tail -2
  rm -rf "$DIST_DIR"
  echo "✅ Created ${DMG_NAME}"

  echo ""
  echo "▶ Gatekeeper check on DMG (informational until Developer ID + notarization)..."
  if spctl -a -vvv "$DMG_NAME"; then
    echo "✅ DMG accepted by spctl"
  else
    echo "ℹ️  DMG not accepted by Gatekeeper. This is expected for the current bridge distribution path."
  fi
}

sign_dmg_for_sparkle() {
  local sign_output

  resolve_sparkle_tools

  echo ""
  echo "▶ Signing DMG for Sparkle..."
  sign_output=$("$SPARKLE_BIN/sign_update" "$DMG_NAME")
  ED_SIGNATURE=$(echo "$sign_output" | grep -o 'sparkle:edSignature="[^"]*"' | cut -d'"' -f2)
  DMG_LENGTH=$(echo "$sign_output" | grep -o 'length="[^"]*"' | cut -d'"' -f2)
  if [ -z "$ED_SIGNATURE" ]; then
    echo "❌ Failed to sign DMG. Is the private key in your keychain?"
    exit 1
  fi
  echo "✅ DMG signed (length: ${DMG_LENGTH} bytes)"
}

publish_release() {
  local pub_date metadata_branch appcast_link

  sign_dmg_for_sparkle

  echo ""
  echo "▶ Updating appcast.xml..."
  pub_date=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
  DMG_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/${DMG_NAME}"
  metadata_branch="$CURRENT_BRANCH"
  appcast_link="https://raw.githubusercontent.com/${GITHUB_REPO}/${metadata_branch}/appcast.xml"

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
            <pubDate>${pub_date}</pubDate>
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

  if [ "$CURRENT_BRANCH" = "main" ]; then
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
  else
    echo ""
    echo "▶ Skipping GitHub release on branch ${CURRENT_BRANCH}"
    echo "   Branch preview mode avoids creating repo-wide release tags/assets."
  fi

  echo ""
  echo "▶ Publishing release metadata to ${metadata_branch}..."
  git add appcast.xml "$VERSION_PLIST"
  git commit -m "release: v${VERSION}" || echo "(release metadata unchanged)"
  git push origin "$metadata_branch"
  echo "✅ Release metadata pushed to ${metadata_branch}"

  if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "ℹ️  Branch preview appcast: ${appcast_link}"
  fi
}

sync_version_metadata
require_server_bundle
build_app
bundle_server_payload
resign_app
verify_app_bundle
create_dmg

if [ "$RELEASE_MODE" = "publish" ]; then
  publish_release
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$RELEASE_MODE" = "publish" ]; then
  echo "✅ Released v${VERSION}"
  echo "   DMG     → $(pwd)/${DMG_NAME}"
  echo "   Appcast → https://raw.githubusercontent.com/${GITHUB_REPO}/${CURRENT_BRANCH}/appcast.xml"
  echo "   Mode    → publish"
else
  echo "✅ Packaged v${VERSION}"
  echo "   DMG  → $(pwd)/${DMG_NAME}"
  echo "   Mode → local"
  echo "   Next → share the DMG manually or rerun from main without WHALE_RELEASE_MODE=local"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
