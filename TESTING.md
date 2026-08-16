# Whale testing workflow

Assuming “Dev and Release” are the two builds being tested:

## Daily development

1. Run the `Whale Dev` scheme from Xcode.
2. Keep that build installed in one stable location.
3. Grant Accessibility to that exact `Whale Dev.app` once.
4. Use the app’s normal settings and onboarding flow while iterating.

## Production/update checks

1. Quit the Dev build before testing Release.
2. Run the `Whale` scheme, or install the signed package from the Release build.
3. Test updates using the same `/Applications/Whale.app` location and the same Developer ID identity.
4. Return to the Dev scheme for coding; if macOS shows both builds in Accessibility, enable the one you are actually running.

Dev and production intentionally have different bundle IDs and Accessibility permissions:

- Dev: `com.sumitrk.transcribe-meeting.dev` / **Whale Dev**
- Production: `com.sumitrk.transcribe-meeting` / **Whale**

## AI Actions checks

Before a release, run the `Whale Dev` test action and manually exercise:

1. Left Control tap with selection text, clipboard text, and a copied image.
2. Left Control used as a real modifier; the native shortcut must pass through and AI Actions must not start.
3. Escape during recording, transcription, and generation; each run must cancel without late insertion.
4. Secure-field activation; no selection or clipboard content should be persisted or sent.
5. Missing, invalid, and replaced OpenRouter keys.
6. Insertion into an editable field and copy fallback into a non-editable destination.
7. History search, image detail, deletion, clear-all, app restart, and locked-database reset.

The release package script also verifies the pinned Pi version/hash, the arm64-only app and Pi architectures, bundled notices, and nested code signatures.

## If Accessibility disappears

1. Open Whale Settings → Permissions → Accessibility.
2. Click **Open in System Settings**.
3. Enable Whale in Privacy & Security → Accessibility.
4. If it is still missing, click `+`, select the exact `Whale.app` you launched, enable it, then click **Re-check**.

The reset flow now re-registers the current app before opening System Settings. Avoid manually running `tccutil reset` unless you intentionally want to repeat the first-install permission test.
