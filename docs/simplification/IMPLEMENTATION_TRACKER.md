# Codebase simplification implementation tracker

This tracker is the coordination source for the recommendations from the simplification audit. One slice is implemented and verified before the next starts.

## Operating rules

1. Read this file and `IMPLEMENTATION_LOG.md` before changing code.
2. One implementation writer at a time in the main worktree. Sub-agents may inspect, test, or review; they do not edit the shared worktree.
3. Each recommendation gets its own branch/checkpoint and focused validation. Do not mix unrelated changes.
4. Update this tracker and append the log before handing work to another session.
5. Never reset or overwrite pre-existing worktree changes.
6. Every completed slice must include a user-facing handoff: what changed, exactly how to test it, its user/technical impact, residual risks, and the next slice.

Statuses: `queued` → `active` → `verified` (or `blocked` / `skipped`).

## New-session startup

1. Confirm the repository root and run `git status --short` and `git branch --show-current`.
2. Read this tracker and `IMPLEMENTATION_LOG.md`.
3. Read the active row's **Scope**, then inspect those files and their callers/tests before editing.
4. Preserve all changes outside the active row; if no row is active, start BASE or the listed **Next slice**.
5. After the slice, update the row and append a log entry before ending the session.

## Current state

- **Coordinator:** parent session / next available session
- **Active slice:** none
- **Baseline tests:** passed (`xcodebuild test`, all suites)
- **Baseline build:** passed as part of baseline test run
- **Worktree at tracker creation:** `M Whale/Sources/TranscribeMeetingApp.swift` — preserve; not part of this plan unless explicitly claimed.
- **Next slice:** R-AI-01

## Recommended sequence

| Order | ID | Slice | Status | Scope | Validation / gate |
|---:|---|---|---|---|---|
| 0 | BASE | Capture baseline and pre-existing failures | verified | status, Xcode test scheme | Record exact command/result before edits |
| 1 | R-OUT-01 | Replace payload-bearing `CharacterProbeResult.realContent(String)` with payload-free `.content` | verified | `TextInsertionManager.swift`, insertion tests | Focused insertion tests; full Xcode test |
| 2 | R-SET-01 | Reuse one shortcut-label formatter | verified | `KeyRecorderView.swift`, possibly settings tests | Fn/Globe, Escape, arrows, ordinary keys, modifiers |
| 3 | R-TRN-02 | Centralize VAD minimum-duration policy | verified | VAD editor/stage/tests | Decide threshold; boundary tests; full Xcode test |
| 4 | R-REPO-01 | Retire stale Node/Python/XcodeGen ownership artifacts | verified | `project.yml`, `index.js`, env/runtime docs, confirmed ignore rules | Tracked-reference search; Xcode show-build-settings; tests |
| 5 | R-CAP-02 | Mix audio without temporary padded arrays | verified | `AudioRecorder.swift`, focused tests if practical | System-only, mic-only, unequal, empty, combined audio |
| 6 | R-AI-01 | Replace correlated AI-action optionals with `ActiveRun` | queued | `AIActionCoordinator.swift`, coordinator tests | Early release, cancellation, supersession, timeout/failure, history finalization |
| 7 | R-TRN-01 | Centralize model-operation task lifecycle | queued | `LocalTranscriptionService.swift`, model tests | Install/reset/connect, cancellation, progress, stale cleanup |
| 8 | R-CAP-01 | Unify hotkey monitor ownership and registration policy | queued | `HotkeyManager.swift` | Full/local/stopped modes; Fn/Globe; regular PTT; repeated rebuilds |
| 9 | R-APP-01 | Represent AppState recording lifecycle as one activity phase | queued | `AppState.swift`, transition tests | Early release, unavailable model, recorder failure, normal flows, AI independence |
| 10 | R-REPO-02 | Archive historical specifications and exploratory designs | queued | `Spec/v0`, `Spec/v1`, `v2`, Hopper notes, links | Tracked-link search; Markdown/reference validation |

## Dependencies and parallelism

- **Safe analysis in parallel:** independent read-only reviews, test-design work, and evidence checks can run concurrently.
- **Implementation policy:** keep code changes sequential. Even slices with disjoint files share the Xcode target, test baseline, tracker, and worktree; parallel writers add merge and verification cost without shortening the critical path.
- **Natural dependency chain:** BASE → R-OUT-01 → R-SET-01 → R-TRN-02 → R-REPO-01 → R-CAP-02 → R-AI-01 → R-TRN-01 → R-CAP-01 → R-APP-01 → R-REPO-02.
- **Possible reorder:** R-OUT-01, R-SET-01, R-REPO-01, R-REPO-02, and R-CAP-02 are relatively independent, but the listed order minimizes risk and keeps one clear handoff.
- **Sub-agent rule:** use sub-agents as read-only reviewers or isolated implementation candidates. The coordinator owns integration, tracker updates, tests, and final acceptance.

## Required post-implementation handoff

Before marking a slice `verified`, append this to `IMPLEMENTATION_LOG.md` and include it in the final response:

- **What changed:** files and behavior changed, in plain language.
- **How to test:** exact commands plus any manual steps or focused test names.
- **Impact:** what users/developers gain, and what behavior intentionally stays the same.
- **Residual risks / skipped work:** known limits and why they are deferred.
- **Next slice:** the next tracker ID.

## Per-slice acceptance checklist

- [ ] Confirm the slice and scope in this tracker.
- [ ] Inspect current callers and tests before editing.
- [ ] Create/use the slice branch according to `CLAUDE.md`.
- [ ] Make the smallest behavior-preserving change.
- [ ] Add only focused regression coverage needed for non-trivial logic.
- [ ] Run focused validation and the full Xcode test command.
- [ ] Run `git diff --check` and inspect the diff.
- [ ] Record commands, results, failures, and residual risks in `IMPLEMENTATION_LOG.md`.
- [ ] Add the required post-implementation handoff: what changed, how to test, impact, residual risks, and next slice.
- [ ] Explain the same handoff in the final response.
- [ ] Mark this row `verified` only after the functional gate passes.

## Explicitly skipped findings

NormalizedEditingState wrapper; `ContextSnapshot.capturedAt`; AudioRecorder write-only fields; pipeline abstraction; backend protocol defaults; security-scoped URL/bookmark pairs; onboarding integer step; custom settings window positioning; SQLCipher/FTS/image deduplication; accessibility heuristics/Pi JSONL framing; separate AppState and AI lifecycles; shared logging/runtime/Keychain; generated Xcode/resource/signing contract; inactive Python backend; test framework/tooling.
