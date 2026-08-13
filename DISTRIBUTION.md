# Whale Distribution Notes

This repo supports public distribution outside the Mac App Store.

What is supported now:
- A stable app identity for Accessibility/TCC across updates, as long as the bundle identifier and signing identity stay the same.
- A signed app bundle that remains immutable after packaging.
- Sparkle update signing for update authenticity.
- Developer ID Application signing with Hardened Runtime.
- Apple notarization and ticket stapling for Gatekeeper acceptance.

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
- Whale's Release configuration uses Developer ID Application signing and Hardened Runtime; `distribute.sh` notarizes and staples every DMG before publishing it.

The Release app intentionally remains unsandboxed. A paid Apple Developer membership does not require App Sandbox for Developer ID distribution outside the Mac App Store, and Whale needs global hotkeys, Accessibility-driven text insertion, and user-selected filesystem access. App Sandbox would be required for Mac App Store distribution and would need a separate capability review.

## Build Pipeline

Default publish flow:

1. Build, verify, package, notarize, staple, sign for Sparkle, update `appcast.xml`, and publish.
```bash
./distribute.sh
```

This default flow:
- prompts for the new marketing version
- increments the build number
- builds and verifies the app bundle
- creates the DMG
- notarizes the DMG with Apple and staples the ticket
- verifies Gatekeeper acceptance
- signs the DMG for Sparkle
- updates `appcast.xml`
- commits and pushes release metadata to the current branch
- on `main`, creates the GitHub release

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

These commands must also pass for the packaged DMG:

```bash
xcrun stapler validate Whale.dmg
spctl -a -vvv -t open --context context:primary-signature Whale.dmg
```

The published DMG should open normally on a clean Mac. Users still need to grant Microphone and Accessibility permissions because those are runtime privacy permissions, not code-signing workarounds.

## Update Expectations

Stable Accessibility behavior across updates depends on:
- the same bundle identifier: `com.sumitrk.transcribe-meeting`
- the same signing identity
- no ad-hoc re-signing during packaging

Sparkle EdDSA signing protects update authenticity, but it does not replace macOS code signing or notarization.

## Publish Prerequisites

The default `./distribute.sh` flow expects:
- `gh` is installed and authenticated
- the `Developer ID Application: Firdaosh Bano (W23Z9F5RG4)` identity is available in the login Keychain
- the `Whale Notary` notarytool profile is available in the login Keychain
- the Sparkle private key is available in your keychain
- Sparkle tools have been built by Xcode at least once

To use another local notarization profile, set `WHALE_NOTARY_PROFILE` when running the script.

GitHub release creation only happens when the current branch is `main`.
