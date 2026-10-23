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
- Direct commits to `main` are allowed.
- Use a branch only when isolated review or experimentation is useful.
