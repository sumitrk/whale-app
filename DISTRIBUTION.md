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
- the pinned arm64 Pi 0.72.1 download, verification, embedding, and AI Actions third-party notices

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

Pi is not installed independently on the user's Mac and its 73 MB executable is not stored in Git. The first local Xcode build downloads the official pinned Apple Silicon archive, verifies both archive and executable SHA-256 checksums, and caches it under `Whale/Resources/Pi/pi/`. Later builds work offline from that ignored cache. Xcode embeds the verified runtime in `Whale.app`, so end users receive it as part of the signed application and do not need Pi, Node.js, npm, or Bun installed.

Default publish flow:

1. Build, verify, package, notarize, staple, sign for Sparkle, update `appcast.xml`, and publish.
```bash
./distribute.sh
```

This default flow:
- prompts for the new marketing version
- increments the build number
- prepares the verified, pinned Pi runtime when it is not already cached
- builds and verifies the app bundle
- verifies that Whale and bundled Pi are arm64-only and that Pi matches the pinned version and SHA-256
- signs the nested Pi executable and SQLCipher framework before signing the app bundle
- gives the Bun-based Pi child only its dedicated JIT/executable-memory signing entitlements; Whale keeps its separate app entitlements
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
codesign --verify --strict --verbose=4 /Applications/Whale.app/Contents/Resources/Pi/pi/pi
/Applications/Whale.app/Contents/Resources/Pi/pi/pi --version
```

These commands must also pass for the packaged DMG:

```bash
xcrun stapler validate Whale.dmg
spctl -a -vvv -t open --context context:primary-signature Whale.dmg
```

The published DMG should open normally on a clean Mac. Users still need to grant Microphone and Accessibility permissions because those are runtime privacy permissions, not code-signing workarounds.

## Accessibility Identity Migration

The first Developer ID release changed Whale's macOS code identity from the old Apple Development certificate. macOS intentionally does not transfer an Accessibility grant between those identities. When the current signed app is untrusted, Whale offers a one-click reset of its stale Accessibility record, then opens the correct System Settings pane for the user to re-enable the current Whale entry. It cannot grant the permission silently.

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
