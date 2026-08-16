#!/bin/bash
# distribute.sh — deterministic packaging pipeline for Whale.
# The checked-in Whale.xcodeproj is the canonical build/signing source of truth.
#
# Default mode is publish for public distribution:
# - builds the app
# - verifies bundle integrity
# - creates a DMG
# - notarizes and staples the DMG
#
# On main, publish mode also creates the GitHub release and pushes release
# metadata to main. On other branches, publish mode behaves like a branch
# preview: it signs the DMG, updates appcast.xml, and pushes the current branch
# without creating a repo-wide GitHub release.
#
# Optional local-only dry run:
#   WHALE_RELEASE_MODE=local ./distribute.sh
set -euo pipefail

APP_NAME="Whale"
SCHEME="Whale"
DERIVED_DATA="build/xcode"
DIST_DIR="build/dist_staging"
DMG_NAME="${APP_NAME}.dmg"
GITHUB_REPO="sumitrk/whale-app"
RELEASE_MODE="${WHALE_RELEASE_MODE:-publish}"
RUN_SMOKE_TEST="${WHALE_SMOKE_TEST:-0}"
NOTARY_PROFILE="${WHALE_NOTARY_PROFILE:-Whale Notary}"
SIGNING_IDENTITY="${WHALE_SIGNING_IDENTITY:-Developer ID Application}"
CURRENT_BRANCH="$(git branch --show-current)"

if [ "$RELEASE_MODE" != "local" ] && [ "$RELEASE_MODE" != "publish" ]; then
  echo "❌ Unsupported WHALE_RELEASE_MODE: $RELEASE_MODE"
  echo "   Use WHALE_RELEASE_MODE=local or WHALE_RELEASE_MODE=publish"
  exit 1
fi

VERSION_PLIST="Whale/Info.plist"
APP_PATH=""
VERSION=""
BUILD=""
SPARKLE_BIN=""
ED_SIGNATURE=""
DMG_LENGTH=""
DMG_URL=""
PI_VERSION="0.72.1"
PI_SHA256="d2ab03267a9d13d029195aa374ecfe9bd0305e3fcf120c92c96bedfac25bd2dc"

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
  current_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$VERSION_PLIST")
  current_build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$VERSION_PLIST")
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
  local ws_state project_dir build_log

  ws_state="${DERIVED_DATA}/SourcePackages/workspace-state.json"
  if [ -f "$ws_state" ]; then
    project_dir="$(pwd)"
    sed -i '' "s|\"path\" : \"[^\"]*/${DERIVED_DATA}/|\"path\" : \"${project_dir}/${DERIVED_DATA}/|g" "$ws_state" 2>/dev/null || true
  fi

  echo ""
  echo "▶ Building Xcode project (Release, Developer ID signed)..."
  build_log=$(mktemp "${TMPDIR:-/tmp}/whale-xcodebuild.XXXXXX")
  if ! xcodebuild \
    -project Whale.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation \
    clean build >"$build_log" 2>&1; then
    grep -E "(^| )error:" "$build_log" | tail -20 || true
    echo "❌ Xcode build failed. Full log: $build_log"
    exit 1
  fi
  rm -f "$build_log"

  APP_PATH=$(find "$DERIVED_DATA" -name "${APP_NAME}.app" -maxdepth 6 | head -1)
  if [ -z "$APP_PATH" ]; then
    echo "❌ Could not find ${APP_NAME}.app in DerivedData"
    exit 1
  fi
  echo "✅ Built: $APP_PATH"
}

prepare_pi_runtime() {
  echo ""
  echo "▶ Preparing pinned Pi runtime..."
  ./scripts/prepare_pi_runtime.sh
}

verify_embedded_runtime() {
  local app_arches app_binary pi_arches pi_binary pi_hash pi_version notices

  app_binary="$APP_PATH/Contents/MacOS/$APP_NAME"
  pi_binary="$APP_PATH/Contents/Resources/Pi/pi/pi"
  notices="$APP_PATH/Contents/Resources/Pi/THIRD_PARTY_NOTICES.txt"

  if [ ! -x "$pi_binary" ]; then
    echo "❌ Bundled Pi executable is missing or not executable: $pi_binary"
    exit 1
  fi
  if [ ! -f "$notices" ]; then
    echo "❌ AI Actions third-party notices are missing: $notices"
    exit 1
  fi

  app_arches=$(lipo -archs "$app_binary")
  pi_arches=$(lipo -archs "$pi_binary")
  pi_hash=$(shasum -a 256 "$pi_binary" | awk '{print $1}')
  pi_version=$($pi_binary --version)
  if [ "$app_arches" != "arm64" ] || [ "$pi_arches" != "arm64" ]; then
    echo "❌ Whale and Pi must both be arm64 (Whale: $app_arches, Pi: $pi_arches)"
    exit 1
  fi
  if [ "$pi_hash" != "$PI_SHA256" ] || [ "$pi_version" != "$PI_VERSION" ]; then
    echo "❌ Bundled Pi does not match the pinned official release"
    echo "   Expected: v$PI_VERSION / $PI_SHA256"
    echo "   Found:    v$pi_version / $pi_hash"
    exit 1
  fi
  echo "✅ Verified arm64 Pi v${PI_VERSION} and third-party notices"
}

sign_for_distribution() {
  local pi_binary sparkle_framework sparkle_version item

  pi_binary="$APP_PATH/Contents/Resources/Pi/pi/pi"
  sparkle_framework="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  sparkle_version="$sparkle_framework/Versions/Current"

  echo ""
  echo "▶ Signing embedded code with Developer ID..."
  codesign --force \
    --options runtime \
    --timestamp \
    --entitlements Whale/Pi.entitlements \
    --sign "$SIGNING_IDENTITY" \
    "$pi_binary"

  for item in \
    "$APP_PATH/Contents/Frameworks/SQLCipher.framework" \
    "$sparkle_version/Autoupdate" \
    "$sparkle_version/Updater.app" \
    "$sparkle_version/XPCServices/Downloader.xpc" \
    "$sparkle_version/XPCServices/Installer.xpc" \
    "$sparkle_framework"; do
    codesign --force \
      --options runtime \
      --timestamp \
      --preserve-metadata=identifier,entitlements,requirements \
      --sign "$SIGNING_IDENTITY" \
      "$item"
  done

  codesign --force \
    --options runtime \
    --timestamp \
    --entitlements Whale/TranscribeMeeting.entitlements \
    --sign "$SIGNING_IDENTITY" \
    "$APP_PATH"
  echo "✅ Embedded code signed with Developer ID"
}

verify_app_bundle() {
  local smoke_root smoke_app app_codesign_details app_requirement pi_binary

  pi_binary="$APP_PATH/Contents/Resources/Pi/pi/pi"

  echo ""
  echo "▶ Verifying app bundle..."
  codesign --verify --deep --strict --verbose=4 "$APP_PATH"
  codesign --verify --strict --verbose=4 "$pi_binary"
  if ! codesign -d --entitlements - "$pi_binary" 2>&1 | grep -q "com.apple.security.cs.allow-jit"; then
    echo "❌ Bundled Pi is missing its Bun/JIT signing entitlements"
    exit 1
  fi
  app_codesign_details=$(codesign -dvvv "$APP_PATH" 2>&1)
  if ! printf "%s\n" "$app_codesign_details" | grep -q "Authority=Developer ID Application:"; then
    echo "❌ App is not signed with a Developer ID Application certificate."
    printf "%s\n" "$app_codesign_details"
    exit 1
  fi
  if ! printf "%s\n" "$app_codesign_details" | grep -q "flags=.*runtime"; then
    echo "❌ Hardened Runtime is not enabled on the Release app."
    printf "%s\n" "$app_codesign_details"
    exit 1
  fi
  printf "%s\n" "$app_codesign_details" | grep -E "^(Authority|TeamIdentifier|Timestamp|Runtime Version)="
  app_requirement=$(codesign -dr - "$APP_PATH" 2>&1)
  printf "%s\n" "$app_requirement" | tail -1

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
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_NAME"
  codesign --verify --verbose=2 "$DMG_NAME"
  echo "✅ Created and signed ${DMG_NAME}"
}

notarize_dmg() {
  local notarization_result notarization_status submission_id

  echo ""
  echo "▶ Notarizing DMG with Apple..."
  notarization_result=$(xcrun notarytool submit "$DMG_NAME" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json)
  printf "%s\n" "$notarization_result"
  notarization_status=$(printf "%s" "$notarization_result" | plutil -extract status raw -o - -)
  submission_id=$(printf "%s" "$notarization_result" | plutil -extract id raw -o - -)
  if [ "$notarization_status" != "Accepted" ]; then
    echo "❌ Apple notarization failed (submission: $submission_id, status: $notarization_status)"
    echo "   Inspect it with: xcrun notarytool log $submission_id --keychain-profile '$NOTARY_PROFILE'"
    exit 1
  fi

  echo "▶ Stapling notarization ticket..."
  xcrun stapler staple "$DMG_NAME"
  xcrun stapler validate "$DMG_NAME"

  echo "▶ Verifying Gatekeeper acceptance..."
  spctl -a -vvv -t open --context context:primary-signature "$DMG_NAME"
  echo "✅ DMG is notarized, stapled, and accepted by Gatekeeper"
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
  local pub_date metadata_branch appcast_link release_commit_message

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

  echo ""
  echo "▶ Publishing release metadata to ${metadata_branch}..."
  git add appcast.xml "$VERSION_PLIST"
  if git diff --cached --quiet; then
    echo "❌ No release metadata changes were staged. Aborting publish."
    exit 1
  fi

  release_commit_message="release: v${VERSION}"
  git commit -m "$release_commit_message"
  git push origin "$metadata_branch"
  echo "✅ Release metadata pushed to ${metadata_branch}"

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
        --target "$metadata_branch" \
        --title "v${VERSION}" \
        --notes "Whale v${VERSION}" \
        2>&1 && echo "✅ GitHub release created" || echo "⚠️  Release may already exist — upload DMG manually"
    fi
  else
    echo ""
    echo "▶ Skipping GitHub release on branch ${CURRENT_BRANCH}"
    echo "   Branch preview mode avoids creating repo-wide release tags/assets."
  fi

  if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "ℹ️  Branch preview appcast: ${appcast_link}"
  fi
}

sync_version_metadata
prepare_pi_runtime
build_app
verify_embedded_runtime
sign_for_distribution
verify_app_bundle
create_dmg
notarize_dmg

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
