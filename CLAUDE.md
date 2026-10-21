# Project Rules for Claude

## Runtime
- The app no longer depends on a bundled Python server.
- The app targets Apple Silicon Macs only.
- Transcription runs through the `FluidAudio` Swift package and Core ML.
- Bark 3.0 Clean (Underdog, CC BY 4.0) is a Core ML conversion Whale hosts on R2. It removes
  fillers while transcribing, which replaced the separate S1-mini Cleanup stage. See
  `Whale/Resources/Licenses/Bark-3.0-Clean/README.md` before changing its credit in the UI.
- Build and package the app with Xcode and the checked-in `Whale.xcodeproj`.

## SwiftUI
- Use the `swiftui-pro` skill (`.agents/skills/swiftui-pro`) for every Swift or SwiftUI change.
- Settings pages are built from the components in `Whale/Sources/Settings`, copied from the
  Spark app (`~/Downloads/Projects/spark/Spark/Settings`): `SettingsPageLayout`, `SettingsSection`
  cards and the `Settings*Row` types. Use them rather than `Form`, so pages keep Spark's look.

## Git Workflow
- **Never commit directly to `main`**
- For every plan step or feature, create a branch first:
  ```bash
  git checkout -b step-02-swift-menubar-shell
  # ... do the work, commit along the way ...
  git push origin step-02-swift-menubar-shell
  ```
- Once the step is complete and tested, merge into main:
  ```bash
  git checkout main
  git merge step-02-swift-menubar-shell
  git push origin main
  git branch -d step-02-swift-menubar-shell
  ```
- Branch naming: `step-XX-<short-description>` for plan steps, `feat/<short-description>` for features, `fix/<short-description>` for bug fixes
- This makes it easy to revert any step by reverting the merge commit
