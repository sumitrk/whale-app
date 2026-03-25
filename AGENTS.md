# Project Rules for Codex

## Runtime
- The app is fully native Swift and no longer depends on a bundled Python server.
- Transcription runs through the `FluidAudio` Swift package and Core ML.
- Build and package the app with Xcode and the checked-in `Whale.xcodeproj`.

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
