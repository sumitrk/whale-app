# Whale Distribution Notes

This repo currently supports a bridge distribution model for tester and hobby installs.

What is supported now:
- A stable app identity for Accessibility/TCC across updates, as long as the bundle identifier and signing identity stay the same.
- A signed app bundle that remains immutable after packaging.
- Sparkle update signing for update authenticity.

What is not supported yet:
- Zero-friction public install on a clean Mac.
- Gatekeeper acceptance of the DMG or app via Developer ID.
- Notarization and stapling.

## Source of Truth

The checked-in [Whale.xcodeproj](/Users/sumitkumar/Downloads/Projects/whale-app/Whale.xcodeproj) is the canonical owner of:
- bundle identifier
- entitlements
- signing behavior
- embedded frameworks

[project.yml](/Users/sumitkumar/Downloads/Projects/whale-app/project.yml) is kept only as legacy reference and should not be treated as authoritative for release behavior.

## First Principles

Three independent properties must hold for distribution to behave correctly:

1. Identity
- Accessibility trust is tied to a stable signed app identity, not just the app name.
- Ad-hoc signing breaks this because the designated requirement collapses to a changing `cdhash`.

2. Integrity
- The installed app bundle must not change after signing.
- Nothing should write into `Whale.app/Contents/...` at runtime.
- Mutable state belongs in `~/Library/Application Support`, `~/Library/Caches`, or `/tmp`.

3. Distribution Trust
- Public "download and open normally" distribution requires Developer ID signing and notarization.
- Apple Development signing is acceptable for bridge distribution and local testing, but Gatekeeper may still reject the app or DMG on a clean Mac.

## Build Pipeline

Default publish flow:

1. Build the bundled server artifact.
```bash
./scripts/build_server_binary.sh
```

2. Build, verify, package, sign for Sparkle, update `appcast.xml`, and publish.
```bash
./distribute.sh
```

This default flow:
- prompts for the new marketing version
- increments the build number
- builds and verifies the app bundle
- creates the DMG
- signs the DMG for Sparkle
- updates `appcast.xml`
- on `main`, creates the GitHub release
- commits and pushes release metadata to the current branch

Optional post-launch integrity smoke test:
```bash
WHALE_SMOKE_TEST=1 ./distribute.sh
```

Optional local-only dry run:
```bash
WHALE_RELEASE_MODE=local ./distribute.sh
```

Local mode packages the current app version without editing `Whale/Info.plist` or publishing release metadata.

Branch behavior:
- running `./distribute.sh` on `main` performs the real release flow
- running `./distribute.sh` on any other branch performs a branch preview release
- branch preview mode signs the DMG and updates `appcast.xml`, but skips the repo-wide GitHub release so you can test packaging without polluting `main`

## Verification Contract

These commands should pass on the packaged app:

```bash
codesign --verify --deep --strict --verbose=4 /Applications/Whale.app
codesign -dr - /Applications/Whale.app
```

These commands are informative for the current bridge path:

```bash
spctl -a -vvv /Applications/Whale.app
spctl -a -vvv Whale.dmg
```

Expected behavior today:
- `codesign --verify ...` must pass.
- `spctl` may still reject the app or DMG because the build is Apple Development signed, not Developer ID signed/notarized.

## Manual Install Expectations

For a clean tester machine:

1. Remove any old Whale app from `/Applications`.
2. Reset Accessibility trust if needed:
```bash
tccutil reset Accessibility com.sumitrk.transcribe-meeting
```
3. Install the new `Whale.app` from the DMG.
4. If macOS blocks the first launch, use Finder `right-click > Open`, or remove quarantine manually if appropriate for your test setup.
5. Grant Accessibility once after launch.

## Update Expectations

Stable Accessibility behavior across updates depends on:
- the same bundle identifier: `com.sumitrk.transcribe-meeting`
- the same signing identity
- no ad-hoc re-signing during packaging

Sparkle EdDSA signing protects update authenticity, but it does not replace macOS code signing or notarization.

## Future Public Distribution

To support true "download and just use it" installs:

1. Join the Apple Developer Program.
2. Switch release signing from Apple Development to Developer ID Application.
3. Notarize and staple the app or DMG.
4. Keep Sparkle signing for update authenticity.

## Publish Prerequisites

The default `./distribute.sh` flow expects:
- `gh` is installed and authenticated
- the Sparkle private key is available in your keychain
- Sparkle tools have been built by Xcode at least once

GitHub release creation only happens when the current branch is `main`.
