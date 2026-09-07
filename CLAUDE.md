# Project Rules for Claude

## Runtime
- The app no longer depends on a bundled Python server.
- The app targets Apple Silicon Macs only.
- Transcription runs through the `FluidAudio` Swift package and Core ML.
- The optional dictation Cleanup stage runs S1-mini by Superwhisper through `mlx-swift` /
  `mlx-swift-lm`. See `Whale/Resources/Licenses/S1-mini/README.md` before touching how the
  model is named in the UI — the name is a licence term.
- Build and package the app with Xcode and the checked-in `Whale.xcodeproj`.
- Building requires Xcode's Metal Toolchain component, which MLX's shaders need and Xcode 26
  no longer installs by default. On a fresh machine or CI runner:
  `xcodebuild -downloadComponent MetalToolchain` (~690 MB, one time).

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
