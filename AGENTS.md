# Project Rules for Codex

## Runtime
- The app is fully native Swift and no longer depends on a bundled Python server.
- Transcription runs through the `FluidAudio` Swift package and Core ML.
- Build and package the app with Xcode and the checked-in `Whale.xcodeproj`.

## Git Workflow
- Direct commits to `main` are allowed.
- Use a branch only when isolated review or experimentation is useful.
