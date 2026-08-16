# Project Rules for Codex

## Runtime
- The app no longer depends on a bundled Python server.
- The app targets Apple Silicon Macs only.
- Transcription runs through the `FluidAudio` Swift package and Core ML.
- Build and package the app with Xcode and the checked-in `Whale.xcodeproj`.

## Git Workflow
- Direct commits to `main` are allowed.
- Use a branch only when isolated review or experimentation is useful.
