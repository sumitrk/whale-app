# Liquid Glass Settings Redesign

**Status:** Implemented; manual visual QA pending
**Date:** 2026-08-15

## Outcome

Redesign Whale's Settings window around native macOS structure and controls. Whale continues to support macOS 14.2, while the same SwiftUI hierarchy automatically adopts Liquid Glass when running on macOS 26.

This is a structural and visual change, plus one behavior fix. Existing preference behavior, model management, hotkeys, permission flows, file selection, and AI Cleanup behavior remain intact. The one intentional behavior change is Step 6: Settings' "Check for Updates" currently bypasses Sparkle and opens a web page, and is repaired to drive the real updater.

## Confirmed Decisions

- Keep the macOS 14.2 deployment target.
- Use one shared SwiftUI implementation across macOS 14.2 and macOS 26.
- Replace the hand-built settings split with `NavigationSplitView`.
- Make the Settings window resizable within provisional minimum and maximum bounds.
- Use the native sidebar toggle and selected-page window title.
- Do not add back/forward controls or settings search.
- Use grouped forms, adaptive section backgrounds, and native controls.
- Let standard controls and navigation adopt Liquid Glass automatically; do not cover content cards in explicit glass.
- Respect the user's system accent color.
- Use adaptive SwiftUI thumbnails only for meaningful transcription-model choices.
- Use the same native grouped model presentation in Settings and onboarding.
- Keep AI Cleanup for now, but give it only a minimal compatibility pass because it will be removed separately.
- Use the canonical terms in `CONTEXT.md`, including **Transcription**, **AI Cleanup**, and **Transcript Mode**.

No ADR is needed. This is a reversible adoption of Apple's standard navigation and form components, with no surprising architectural trade-off.

## Apple Guidance Driving the Design

- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass): existing apps gain the current appearance through standard SwiftUI and AppKit components; custom navigation backgrounds should be removed; grouped forms and split views are preferred.
- [Materials — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/materials): Liquid Glass is a functional layer for navigation and controls, not a general content background.
- [NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview): provides native sidebar sizing, collapsing, toolbar integration, and fluid resizing.
- [Form](https://developer.apple.com/documentation/swiftui/form) and [GroupedFormStyle](https://developer.apple.com/documentation/swiftui/groupedformstyle): provide platform-appropriate settings layout and metrics.
- [WindowResizability](https://developer.apple.com/documentation/swiftui/windowresizability): a Settings scene derives minimum and maximum sizes from its content by default.

## Verified Preconditions

These were checked against the working tree, not assumed:

- `MACOSX_DEPLOYMENT_TARGET = 14.2` in all four build configurations; `SWIFT_VERSION = 5.9`.
- Local toolchain is Xcode 26.5 (build 17F42), so the app builds against the macOS 26 SDK and Liquid Glass applies at runtime on macOS 26.
- `Whale/Info.plist` does **not** set a Liquid Glass compatibility opt-out key, and must not gain one.
- The project uses explicit `PBXFileReference` entries, not synchronized folders, so renaming any source file requires a `project.pbxproj` edit.
- The shared scheme `Whale.xcscheme` builds `Whale Dev.app` and includes the `WhaleTests` testable. No test references `SettingsView`, `ModelSettingsView`, or `SettingsSection`, so no test needs updating for the renames.
- `SettingsSection` is in-memory only (`SettingsCoordinator.selection`); no `UserDefaults` key persists it, so its cases and raw values can be renamed freely.

## Current Codebase Findings

| Area | Current state | Required direction |
| --- | --- | --- |
| Settings shell | `SettingsView` manually composes `HStack`, a `List` fixed at 160 pt, `Divider`, and a fixed `760 × 560` frame. | Replace with `NavigationSplitView` and content-derived window constraints. |
| Navigation | `SettingsView.swift:46` documents that `NavigationSplitView` was deliberately avoided to suppress the sidebar toolbar item. | Deliberately reverse that decision; the native sidebar toggle is now wanted. |
| General | Already a grouped `Form`, 33 lines. | Reorganize into clearly headed native groups and retain behavior. |
| Shortcuts | Already a grouped `Form`; section header reads "Toggle Record  (saves transcript as markdown)"; `KeyBadge` uses fixed `NSColor.controlBackgroundColor`. | Rename the section to Transcript Mode, retain the custom key recorders, use native surrounding controls, use semantic colors. |
| Transcription models | `ModelSettingsView` wraps `TranscriptionModelGroupsView`, which renders `TranscriptionModelCard` — opaque `controlBackgroundColor` cards with hand-painted `largecircle.fill.circle` radios, a "Selected" capsule, and a forced `.blue` progress tint. | Rebuild as grouped native rows. **See "Shared component" below — this view is not settings-only.** |
| Onboarding reuse | `OnboardingView.swift:214` renders the **same** `TranscriptionModelGroupsView(horizontalPadding: 28, contentPadding: 16)` inside a plain `ScrollView`. | Adopt the same native grouped model sections and thumbnails as Settings; see Step 3. |
| AI Cleanup | `PostProcessingSettingsView` is a card-heavy `ScrollView`; `LocalLLMModelCard` paints a radio circle and a "Recommended" capsule for a catalog that contains exactly one model (`qwen3_0_6b_4bit`). | Minimal semantic pass only. The single-item radio is dead UI and should collapse into a plain row. |
| Permissions | Grouped `Form` with `.buttonStyle(.borderless)` and a forced `.blue` on "Grant Access →". | Keep structure; use system button roles and semantic foreground styles. |
| Updates | **Bug.** Sparkle is fully wired — `SPUStandardUpdaterController` in `TranscribeMeetingApp.swift:24`, `SUFeedURL` in `Info.plist:27`, a working `updater.checkForUpdates()` in `MenuBarView.swift:39`. But `GeneralSettingsView` never receives the updater and its "Check for Updates" button opens the GitHub releases page in a browser. | Fix in Step 6: drive the real updater from Settings. |
| Window coordination | `SettingsWindowAccessor` registers the `NSWindow` so `SettingsCoordinator.focus(section:)` can raise it; `MenuBarView.swift:48` calls it with the current selection and falls back when it returns `false`. | Preserve exactly; do not introduce a custom window controller. |

## Resolved Contradictions

The previous draft contained two internal conflicts. Both are resolved here.

### 1. The model list is shared with onboarding

`TranscriptionModelGroupsView` and `TranscriptionModelCard` are used by both `ModelSettingsView` and `OnboardingView`'s `ModelStep`. The latest product decision is to redesign both surfaces together so onboarding also adopts the native macOS structure and Liquid Glass appearance.

**Resolution:** split presentation from lifecycle logic.

- Extract the state-derived content — action title and role, status message, progress value/phase, error text, local path, reset availability — into a plain, view-free helper (`TranscriptionModelRowModel`) in `LocalTranscriptionService.swift` next to `BuiltInModelCatalog`. It takes a `BuiltInModelDescriptor` plus a `NativeModelInstallState` and returns values, not views.
- Settings gets a new grouped-`Form` presentation built on that helper.
- Onboarding reuses the same active-model and model-management sections inside its own grouped `Form`.

This keeps a single source of truth for lifecycle wording and presentation while allowing each containing screen to retain its own header and flow controls.

### 2. `Picker` options cannot contain buttons

The previous draft asked for a radio-group `Picker` for exclusive selection *and* for each model's Install / Retry / Change Folder / Reset Cache buttons to live in the same row. A SwiftUI `Picker` option is a label, not an interactive container; controls placed inside are inert, and `.radioGroup` on macOS does not render rich labels reliably.

**Resolution:** separate selection from management, which is also what Apple's own settings do.

- **Active model** — one `Section` at the top of the Transcription page containing a single labeled `Picker` bound to `SettingsStore.selectedBuiltInModelID`, listing only models whose `installState` is `.ready`. When nothing is ready, replace the `Picker` with explanatory text rather than an empty control. This is plain, works identically on 14.2 and 26, and needs no fallback design.
- **Manage models** — one `Section` per `BuiltInModelGroup` (Parakeet, Whisper), one grouped row per model carrying the thumbnail, title, detail, status, progress, error, and every action button.

Selection state is then shown in the manage rows as a passive native indicator (a checkmark on the active model), never as a tappable hand-painted circle.

## Target Information Architecture

Sidebar order:

1. General — `gearshape`
2. Shortcuts — `keyboard`
3. Transcription — `waveform`
4. AI Cleanup — `sparkles`
5. Permissions — `lock.shield`

Each detail page uses its section name as the window title. Pages do not repeat a large in-content title above the first group.

## Step 0 — Spike (gate; must complete before Step 1)

Branch: `feat/liquid-glass-settings-spike`. Throwaway; not merged.

The whole plan rests on `NavigationSplitView` behaving inside a SwiftUI `Settings` scene, which is exactly what the current code says it avoided. Prove it before writing five pages of UI:

1. Does `NavigationSplitView` inside `Settings { }` render the sidebar toggle in the titlebar, and does the sidebar collapse and restore? Check on macOS 26.5 **and** against the 14.2 deployment target.
2. Does `.navigationTitle` on the detail column change the Settings window title? Decide the outcome explicitly: page name only ("General") versus app-qualified ("Whale Settings"). Default to the page name, matching System Settings.
3. Does `.defaultSize(width:height:)` do anything on a `Settings` scene? Apple documents `defaultSize` for `WindowGroup`, `Window`, and `DocumentGroup`; assume it is a no-op here until observed otherwise, and drive the initial size from the root content's `idealWidth`/`idealHeight` plus `.windowResizability(.contentSize)`.
4. Does `SettingsWindowAccessor`, attached as a `.background` on the `NavigationSplitView`, still resolve a non-nil `NSWindow`? `SettingsCoordinator.focus(section:)` returns `false` without it and the menu-bar path degrades.

Record the four answers in this file under a "Spike results" heading. If (1) or (4) fails on 14.2, stop and re-plan the shell; Steps 2–6 are independent of the shell and can still proceed.

## Implementation Plan

Per `CLAUDE.md`, each step is its own branch off `main`, merged only after it builds clean and `WhaleTests` passes.

Only Step 1 is gated on the spike. Steps 2–6 are independent of the shell and of each other, with one ordering constraint: **Step 6 lands before Step 2**, so the General page's update button is rewired before it is restyled. A low-risk order is 5 → 6 → 0 → 1 → 2 → 4 → 3.

### 1. Replace the Settings shell

Branch: `feat/liquid-glass-settings-shell`.

`Whale/Sources/SettingsView.swift`:

- Rename `SettingsSection.model` → `.transcription` (raw value `"Transcription"`, icon `waveform`) and `.postProcessing` → `.aiCleanup` (raw value `"AI Cleanup"`).
- Reorder cases to match the information architecture; `allCases` drives sidebar order.
- Replace the root `HStack`, fixed 160 pt sidebar, `Divider`, and `760 × 560` frame with a two-column `NavigationSplitView`.
- Keep `SettingsCoordinator.selection` non-optional so `focus(section:)` and `MenuBarView.swift:48` keep their current signatures. Bridge to the sidebar with a locally derived optional `Binding<SettingsSection?>` whose setter ignores `nil`; a `NavigationSplitView` sidebar expects optional selection and will not highlight correctly otherwise.
- Sidebar: `List(SettingsSection.allCases, selection:)` with `Label` + `.listStyle(.sidebar)`, `.navigationSplitViewColumnWidth(min: 175, ideal: 200, max: 230)`.
- Apply `.navigationTitle(settingsCoordinator.selection.rawValue)` to the detail content.
- Keep the automatic sidebar toolbar item; add no toolbar history buttons and no search.
- Keep `SettingsWindowAccessor` solely for `registerSettingsWindow(_:)`.
- Root content bounds, defined as `private enum SettingsWindowMetrics` in this file so retuning is a one-line edit:
  - minimum `720 × 520`
  - ideal `860 × 620`
  - maximum `1120 × 820`

`Whale/Sources/TranscribeMeetingApp.swift`:

- Add `.windowResizability(.contentSize)` to the `Settings` scene.
- Add `.defaultSize` only if the spike shows it has an effect.
- Add no macOS 26-only scene code unless visual verification exposes a genuine platform gap.

`Whale/Sources/SettingsCoordinator.swift` and callers: update enum case references only; `focus(section:)` behavior is unchanged. Verify the menu-bar path still opens Permissions directly.

**Checkpoint:** all five pages reachable, deep focus from the menu bar works, window resizes within bounds. Page interiors are untouched at this point.

### 2. Normalize the lasting form pages

Branch: `feat/liquid-glass-settings-forms`.

`GeneralSettingsView.swift`:

- Retain grouped `Form`; add headers "Startup" and "About".
- Launch at Login stays a native `Toggle`.
- "Check for Updates" currently uses `.buttonStyle(.borderless)` inside a `LabeledContent`; use a standard bordered button. Land Step 6 first so this step only restyles the button and never touches its action.
- No decorative artwork; General contains no meaningful visual choice.

`ShortcutsSettingsView.swift`:

- Keep the grouped `Form` and existing `PTTRecorderView` / `KeyRecorderView` behavior verbatim.
- Keep Push-to-Talk first.
- Rename the second section header from `"Toggle Record  (saves transcript as markdown)"` to `"Transcript Mode"`, and move the markdown note into the section footer.
- Keep the transcript-folder chooser inside Transcript Mode; that mode produces the saved transcript.
- Replace `Picker("", …) + .labelsHidden()` with a labeled `Picker("Key", …)` where the grouped form's own label column allows it, dropping the wrapping `LabeledContent`.
- Keep folder paths secondary, middle-truncated, and selectable; give the folder `Image(systemName: "folder")` button an accessibility label ("Choose transcript folder") — it currently has none.
- Restyle `KeyBadge` with `.background(.quaternary)` / `Color(nsColor: .separatorColor)` semantics instead of fixed `NSColor.controlBackgroundColor`. Do not apply Liquid Glass to key badges.

`PermissionsSettingsView.swift`:

- Keep grouped `Form`, SF Symbol labels, status text, and deep links.
- Replace `.buttonStyle(.borderless)` + forced `.foregroundStyle(.blue)` on "Grant Access →" with a standard button; drop the trailing arrow, which is not a macOS convention.
- Keep Granted/Not Granted stated textually as well as by color, so the state survives grayscale and color-blind viewing.
- Ensure both permission actions are keyboard reachable with complete VoiceOver labels.

### 3. Rebuild the Transcription page

Branch: `feat/liquid-glass-transcription-page`. Largest step; land it alone.

**3a. Extract the shared helper.** Add `TranscriptionModelRowModel` to `LocalTranscriptionService.swift` beside `BuiltInModelCatalog`. It maps `(BuiltInModelDescriptor, NativeModelInstallState, isSelected)` to values only — no `View` types — covering `.checking`, `.notInstalled`, `.downloading(progress, phase)`, `.ready`, `.failed(message)`. This is pure and directly unit-testable; add cases to `WhaleTests/TranscriptionModelTests.swift` covering all five states rather than adding a snapshot framework.

**3b. Adopt the shared native model presentation in onboarding.** Replace onboarding's opaque model cards with the same grouped active-model and model-management sections used by Settings. Keep onboarding's own heading, readiness message, and continue flow. This must land in the same commit as 3a so no intermediate commit breaks the build.

**3c. Rename the file and type.** `git mv Whale/Sources/ModelSettingsView.swift Whale/Sources/TranscriptionSettingsView.swift` and rename `ModelSettingsView` → `TranscriptionSettingsView`. Update all four `project.pbxproj` sites: the `PBXBuildFile` entry (~line 20), the `PBXFileReference` entry (~line 100), the group child list (~line 171), and the `Sources` build phase (~line 382). Open the project in Xcode afterward to confirm the file resolves and is not red.

**3d. Build the page.** In `TranscriptionSettingsView`:

- Grouped `Form`. First section "Active model" with the ready-only `Picker` described above. Then one section per `BuiltInModelGroup` using `group.title` as the header.
- Each model row: `TranscriptionModelThumbnail`, title, detail, a checkmark when active, and the state's action button — Install / Choose Folder / Retry / Choose Another Folder / Change Folder / Reset Cache — plus status text, `ProgressView` (determinate when progress is non-nil, indeterminate otherwise), error text, and local path.
- Keep local paths `.textSelection(.enabled)` and allow them to wrap at narrow widths.
- Remove the `controlBackgroundColor` cards, the "Selected" capsule, the hand-painted radio circles, and the forced `.tint(.blue)` on progress.
- Preserve `NSOpenPanel` folder selection and `modelStore.reset(_:)` exactly.

**3e. Thumbnails.** Add `TranscriptionModelThumbnail` in the same file — not a thumbnail framework:

- Compact rounded thumbnail from SwiftUI shapes, semantic gradients, highlights, shadows, and SF Symbols that exist on macOS 14.2.
- Distinct metaphors per catalog entry: **FluidAudio English** (`parakeetEnglishV2`) a waveform/audio plate; **Whisper Large V3 Turbo** (`whisperLargeV3Turbo`) a speech/text processing plate; **Local Whisper Folder** (`whisperLocalFolder`) a dimensional folder with waveform detail.
- Keep selection and status outside the illustration; the thumbnail is never a control.
- Mark it `.accessibilityHidden(true)`; the adjacent title carries the meaning.
- Verify in light, dark, increased contrast, and grayscale.
- No generated PNGs, no asset-catalog entries.

### 4. Give AI Cleanup a minimal compatibility pass

Branch: `fix/ai-cleanup-settings-compat`. Deliberately shallow — this page is scheduled for deletion.

`PostProcessingSettingsView.swift`:

- Change user-facing "Post-processing" to "AI Cleanup" (line 27 title, line 101 body copy).
- Delete the in-content page title; the window title supplies it.
- Convert to a grouped `Form` only insofar as it removes the hand-built cards; keep the prompt `TextEditor`, the model lifecycle, recent previews, and every action working exactly as today.
- Replace fixed `NSColor.controlBackgroundColor` / `windowBackgroundColor` card fills with semantic styles. Keep `NSColor.textBackgroundColor` on the `TextEditor` and preview columns — that one is semantically correct.
- Collapse `LocalLLMModelCard`'s radio circle and "Recommended" capsule into a plain row. The catalog has exactly one model, so the selection control is inert UI.
- Do not generate thumbnails, extract reusable card components, or rename the file or type for a temporary page.
- Leave internal identifiers (`postProcessingEnabled`, `PostProcessingTypes.swift`, pipeline comments) alone; renaming them is churn on code slated for removal.

### 5. Update cross-references and copy

Branch: `fix/settings-terminology`. Can land first — it is independent and reduces noise in later diffs.

- `LocalTranscriptionService.swift:50`, `:52`, `:1155` — "Settings > Model" → "Settings > Transcription".
- `LocalLLMService.swift:19` — "Settings > Post-Processing" → "Settings > AI Cleanup".
- `OnboardingView.swift:316` — "Toggle Recording" → "Transcript Mode".
- `OnboardingView.swift:367` — "Settings → Post-Processing → Local AI Model" → "Settings > AI Cleanup".
- `OnboardingView.swift:312`, `ShortcutsSettingsView.swift:83`, `SettingsStore.swift:24`, `:36`, `:90` — comments to Transcript Mode / AI Cleanup.
- Standardize the separator: the codebase currently mixes `>` and `→`. Use `>` everywhere.

Do not rename persisted `UserDefaults` keys. They are storage identifiers; changing them would drop existing preferences for no user-visible benefit.

### 6. Fix "Check for Updates" in Settings

Branch: `fix/settings-check-for-updates`. Independent of the shell; **land before Step 2** so that step stays purely visual.

The bug: Sparkle is fully configured and works from the menu bar, but Settings never gets the updater. [GeneralSettingsView.swift:21](../../Whale/Sources/GeneralSettingsView.swift:21) opens `https://github.com/sumitrk/whale-app/releases` in a browser instead. A user who checks for updates from Settings — the conventional place to look — gets a web page and a manual download rather than Sparkle's install flow, and gets no signature verification.

- Thread the existing `SPUUpdater?` through as an init parameter, mirroring `MenuBarView(updater:)`: `SettingsView(updater:)` → `GeneralSettingsView(updater:)`. Do not create a second `SPUStandardUpdaterController`; there must be exactly one per process, and `TranscribeMeetingApp` already owns it.
- **Do not read `updater.canCheckForUpdates` directly.** `MenuBarView` gets away with it only because the menu is rebuilt each time it opens. The Settings window is long-lived, so a direct read goes stale and can strand the button as permanently disabled. Use Sparkle's documented SwiftUI pattern: a small `ObservableObject` that republishes `canCheckForUpdates` via `updater.publisher(for: \.canCheckForUpdates)`, driving `.disabled(...)`.
- When the updater is `nil` — `WHALE_DISABLE_SPARKLE=1`, the dev-scheme path via `AppRuntimeInfo.sparkleDisabled` — hide the row entirely, matching `MenuBarView`'s `if let updater`. Do not silently fall back to the web page; that reintroduces the bug under a different condition.
- Keep the Version row and `CFBundleShortVersionString` as they are.
- Retire the hardcoded releases URL. Nothing else references it.

Verify: with Sparkle enabled, the Settings button triggers Sparkle's own update dialog and no browser opens; the button is disabled while a check is already in flight and re-enables afterward; with `WHALE_DISABLE_SPARKLE=1` the row is absent and the rest of General renders normally.

## Validation

Automated, on every branch before merge:

1. `xcodebuild -project Whale.xcodeproj -scheme Whale build`
2. `xcodebuild -project Whale.xcodeproj -scheme Whale test`
3. Treat new availability warnings as failures; all shared UI must stay valid at the 14.2 deployment target.
4. No UI snapshot-test framework for one window. Step 3a's helper carries the testable logic instead.

Manual on macOS 26.5, in priority order — the first four catch nearly everything:

- Sidebar expanded and collapsed; minimum, default, and maximum window sizes.
- Every transcription-model state: checking, not installed, downloading (both determinate and indeterminate), ready, failed with a long error message.
- Full keyboard traversal, focus rings, Space/Return activation, VoiceOver labels.
- Light and dark appearance.
- Non-blue system accent color.
- Clear and tinted Liquid Glass system preferences.
- Reduce Transparency, Reduce Motion, Increase Contrast.
- Long transcript-folder and local-model paths.
- Granted and denied Accessibility/Microphone states.
- Onboarding's model step, confirming the shared grouped model UI remains usable within the onboarding window.
- Menu-bar > Permissions deep focus, both with the Settings window already open and with it never opened.
- Sparkle check from Settings, with the window left open long enough to confirm the button's enabled state does not go stale; plus a `WHALE_DISABLE_SPARKLE=1` run.

macOS 14.2:

- Build against the 14.2 deployment target on every change.
- Smoke test on a macOS 14.x machine or VM before release. The dev machine is macOS 26.5, so deployment-target compilation alone cannot verify the older visual result.
- Confirm the same information architecture and functionality render with the older native material rather than Liquid Glass.

## Acceptance Criteria

- Settings opens and focuses requested sections exactly as before.
- The window resizes only within the provisional bounds, with no clipping or unusable controls.
- macOS 26 presents native Liquid Glass in window chrome, sidebar, navigation, and controls, with no explicit glass on content.
- macOS 14.2 retains a coherent native appearance and all behavior.
- Sidebar order and titles match the confirmed vocabulary.
- All durable settings pages use grouped native structure.
- Transcription selection uses a native `Picker`; no hand-painted radio circles remain anywhere in Settings.
- Onboarding's model step uses the same native model controls and thumbnails as Settings.
- System accent, accessibility preferences, keyboard control, and VoiceOver are respected.
- AI Cleanup remains fully functional and receives no throwaway asset or component work.
- Settings' "Check for Updates" drives Sparkle, matching the menu bar; it opens no browser, its enabled state stays accurate in a long-lived window, and the row is absent when Sparkle is disabled.
- No persisted preference keys, transcription behavior, model behavior, or permission behavior change.

## Rollback

Each step is a separate branch merged with a merge commit, so any step reverts independently via `git revert -m 1`. Step 3 is the only one with a file rename; reverting it restores `ModelSettingsView.swift` and its four `project.pbxproj` entries together.

## Explicit Non-Goals

- Removing AI Cleanup or its cleanup model.
- Redesigning the menu-bar popover or onboarding steps other than the model-selection step.
- Adding settings search or navigation history.
- Creating a custom Liquid Glass abstraction, `NSVisualEffectView`, or `NSGlassEffectView` wrapper.
- Applying `.glassEffect()` to grouped content panels.
- Adding generated raster artwork, new dependencies, or a snapshot-testing dependency.
- Any updater work beyond Step 6 — no appcast changes, no update-channel UI, no automatic-check preference, no `SUFeedURL` change.
- Fixing unrelated transcription, model-installation, or permission bugs discovered during visual work.
