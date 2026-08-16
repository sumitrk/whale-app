# Step 7: Packaging + Distribution

## Goal
Bundle the app with an embedded Python runtime, sign it with an Apple Developer certificate, notarize it so Gatekeeper doesn't block it, package it as a DMG, publish a GitHub Release, and submit a Homebrew Cask so users can install with `brew install --cask transcribe-meeting`.

## What Is Usable After This Step
Anyone with a Mac running macOS 13+ can run `brew install --cask transcribe-meeting` and have the fully working app installed in 30 seconds, with no manual setup, no terminal after that.

---

## Prerequisites

- **Apple Developer account** (free = local dev only, $99/yr = notarization/distribution)
- **Xcode 15+** with command-line tools
- **Python 3.11** standalone runtime (downloaded via `python-build-standalone`)
- **create-dmg** — `brew install create-dmg`
- **GitHub CLI** — `brew install gh`

---

## Part 1: Bundle Python Runtime

### Download python-build-standalone

```bash
# Download a pre-built, self-contained Python 3.11 for Apple Silicon
curl -L https://github.com/indygreg/python-build-standalone/releases/latest/download/\
cpython-3.11.9+20240814-aarch64-apple-darwin-install_only.tar.gz \
-o /tmp/python-standalone.tar.gz

tar -xzf /tmp/python-standalone.tar.gz -C /tmp/
# Result: /tmp/python/bin/python3.11, /tmp/python/lib/, etc.
```

### Install Python packages into the standalone runtime

```bash
/tmp/python/bin/python3.11 -m pip install \
  fastapi uvicorn[standard] python-multipart pydantic \
  mlx-whisper anthropic scipy numpy \
  --no-deps-check
```

### Copy into the Xcode project

```bash
mkdir -p TranscribeMeeting/Resources/python-runtime
cp -r /tmp/python/. TranscribeMeeting/Resources/python-runtime/

mkdir -p TranscribeMeeting/Resources/scripts
cp server/server.py TranscribeMeeting/Resources/scripts/
cp server/transcriber.py TranscribeMeeting/Resources/scripts/
cp server/llm.py TranscribeMeeting/Resources/scripts/
cp server/output.py TranscribeMeeting/Resources/scripts/
```

### Add to Xcode target

In Xcode → Target → Build Phases → Copy Bundle Resources:
- Add `Resources/python-runtime/` folder
- Add `Resources/scripts/` folder

### Update `PythonServer.swift` to use bundled runtime

Replace the `startWithSystemPython()` dev path with:
```swift
func start() async throws {
    guard let pythonPath = Bundle.main.path(
        forResource: "python3.11",
        ofType: nil,
        inDirectory: "python-runtime/bin"
    ),
    let serverScript = Bundle.main.path(
        forResource: "server",
        ofType: "py",
        inDirectory: "scripts"
    ) else {
        // Fallback to system Python for development
        try startWithSystemPython()
        return
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: pythonPath)
    proc.arguments = [serverScript]
    proc.environment = [
        "PYTHONPATH": Bundle.main.resourcePath! + "/scripts",
        "PYTHONHOME": Bundle.main.resourcePath! + "/python-runtime",
        "PATH": Bundle.main.resourcePath! + "/python-runtime/bin",
    ]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try proc.run()
    self.process = proc
}
```

---

## Part 2: Sign the App

### Configure signing in Xcode

1. Xcode → Target → Signing & Capabilities
2. Team: select your Apple Developer account
3. Bundle ID: `com.sumitrk.transcribe-meeting`
4. Signing Certificate: `Developer ID Application` (for distribution outside App Store)

### Required Entitlements

Create `TranscribeMeeting.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Allow outbound network for Claude API -->
    <key>com.apple.security.network.client</key>
    <true/>
    <!-- Microphone -->
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <!-- ScreenCaptureKit -->
    <key>com.apple.security.device.camera</key>
    <false/>
    <!-- Disable sandboxing so Python subprocess can run -->
    <!-- Note: This means no App Store distribution, only direct/Homebrew -->
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

> **Important**: Disabling sandboxing blocks Mac App Store but is required to run Python subprocess. For distribution via GitHub/Homebrew this is fine.

---

## Part 3: Archive and Notarize

### Build the archive

```bash
xcodebuild archive \
  -scheme TranscribeMeeting \
  -archivePath ./build/TranscribeMeeting.xcarchive \
  -configuration Release \
  CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

### Export the .app

```bash
# Create ExportOptions.plist
cat > ExportOptions.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath ./build/TranscribeMeeting.xcarchive \
  -exportPath ./build/export \
  -exportOptionsPlist ExportOptions.plist
```

### Notarize

```bash
# Store credentials once
xcrun notarytool store-credentials "notarytool-profile" \
  --apple-id "your@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"

# Submit for notarization
xcrun notarytool submit ./build/export/TranscribeMeeting.app \
  --keychain-profile "notarytool-profile" \
  --wait

# Staple the notarization ticket
xcrun stapler staple ./build/export/TranscribeMeeting.app
```

---

## Part 4: Create DMG

```bash
create-dmg \
  --volname "TranscribeMeeting" \
  --volicon "TranscribeMeeting/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "TranscribeMeeting.app" 175 190 \
  --hide-extension "TranscribeMeeting.app" \
  --app-drop-link 425 190 \
  "build/TranscribeMeeting-1.0.0.dmg" \
  "build/export/"
```

Notarize the DMG too:
```bash
xcrun notarytool submit build/TranscribeMeeting-1.0.0.dmg \
  --keychain-profile "notarytool-profile" \
  --wait
xcrun stapler staple build/TranscribeMeeting-1.0.0.dmg
```

---

## Part 5: GitHub Release

```bash
# Get SHA256 of the DMG (needed for Homebrew Cask)
shasum -a 256 build/TranscribeMeeting-1.0.0.dmg

# Create a git tag and push
git tag v1.0.0
git push origin v1.0.0

# Create GitHub release and upload DMG
gh release create v1.0.0 \
  --title "TranscribeMeeting v1.0.0" \
  --notes "First standalone release. Menu bar app for macOS 13+.

## What's new
- Menu bar app (no terminal needed)
- ScreenCaptureKit audio capture (no BlackHole needed)
- Guided onboarding with permission prompts
- Settings window (model, API key, output folder)
- macOS notifications on completion

## Install
\`\`\`bash
brew install --cask transcribe-meeting
\`\`\`
Or download the DMG below." \
  build/TranscribeMeeting-1.0.0.dmg
```

---

## Part 6: Homebrew Cask

### Create the cask file

```ruby
# homebrew-cask-transcribe-meeting/Casks/transcribe-meeting.rb
cask "transcribe-meeting" do
  version "1.0.0"
  sha256 "REPLACE_WITH_ACTUAL_SHA256"

  url "https://github.com/sumitrk/transcribe-meeting/releases/download/v#{version}/TranscribeMeeting-#{version}.dmg"

  name "TranscribeMeeting"
  desc "AI-powered meeting transcription for macOS — no terminal required"
  homepage "https://github.com/sumitrk/transcribe-meeting"

  livecheck do
    url :url
    strategy :github_latest
  end

  app "TranscribeMeeting.app"

  zap trash: [
    "~/Library/Application Support/TranscribeMeeting",
    "~/Library/Preferences/com.sumitrk.transcribe-meeting.plist",
  ]
end
```

### Option A: Submit to homebrew/homebrew-cask (public, official)
- Fork `homebrew/homebrew-cask`
- Add cask file to `Casks/t/transcribe-meeting.rb`
- Open a PR (requires 30-day wait + review)

### Option B: Self-hosted tap (faster, for open-source tools)
```bash
# Create a new repo: github.com/sumitrk/homebrew-transcribe-meeting
gh repo create sumitrk/homebrew-transcribe-meeting --public

# Add the cask
mkdir -p Casks
cp transcribe-meeting.rb Casks/
git add . && git commit -m "Add transcribe-meeting cask"
git push

# Users install with:
brew tap sumitrk/transcribe-meeting
brew install --cask transcribe-meeting
```

---

## Part 7: `scripts/build.sh` — Automate the whole process

```bash
#!/bin/bash
set -e

VERSION=$1
if [ -z "$VERSION" ]; then echo "Usage: ./scripts/build.sh 1.0.0"; exit 1; fi

echo "Building TranscribeMeeting v$VERSION..."

# 1. Archive
xcodebuild archive \
  -scheme TranscribeMeeting \
  -archivePath ./build/TranscribeMeeting.xcarchive \
  -configuration Release

# 2. Export
xcodebuild -exportArchive \
  -archivePath ./build/TranscribeMeeting.xcarchive \
  -exportPath ./build/export \
  -exportOptionsPlist scripts/ExportOptions.plist

# 3. Notarize app
xcrun notarytool submit ./build/export/TranscribeMeeting.app \
  --keychain-profile "notarytool-profile" --wait
xcrun stapler staple ./build/export/TranscribeMeeting.app

# 4. Create DMG
create-dmg \
  --volname "TranscribeMeeting" \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "TranscribeMeeting.app" 175 190 \
  --app-drop-link 425 190 \
  "build/TranscribeMeeting-${VERSION}.dmg" \
  "build/export/"

# 5. Notarize DMG
xcrun notarytool submit "build/TranscribeMeeting-${VERSION}.dmg" \
  --keychain-profile "notarytool-profile" --wait
xcrun stapler staple "build/TranscribeMeeting-${VERSION}.dmg"

# 6. Print SHA for Homebrew Cask
echo ""
echo "SHA256 for Homebrew Cask:"
shasum -a 256 "build/TranscribeMeeting-${VERSION}.dmg"

echo ""
echo "Done! Upload build/TranscribeMeeting-${VERSION}.dmg to GitHub Releases."
```

---

## Tests

### Test 1: Clean install from DMG
```
1. Drag TranscribeMeeting.app to /Applications
2. Double-click → Gatekeeper should not block (notarized)
3. Onboarding appears ✅
4. Record a meeting → markdown saved ✅
```

### Test 2: Install from Homebrew tap
```bash
brew tap sumitrk/transcribe-meeting
brew install --cask transcribe-meeting
open /Applications/TranscribeMeeting.app
# Onboarding appears ✅
```

### Test 3: Uninstall and verify cleanup
```bash
brew uninstall --cask transcribe-meeting
brew zap --cask transcribe-meeting
# ~/Library/Application Support/TranscribeMeeting should be gone ✅
```

---

## Done When

- [ ] App builds without errors in Release configuration
- [ ] App is signed with Developer ID certificate
- [ ] App is notarized — no Gatekeeper warning on launch
- [ ] DMG contains app and Applications shortcut
- [ ] GitHub Release exists with DMG attached
- [ ] `brew tap sumitrk/transcribe-meeting && brew install --cask transcribe-meeting` works
- [ ] Clean install from brew runs onboarding and records a meeting successfully

---

**V1 complete!** 🎉
