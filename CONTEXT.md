# Whale

Whale turns captured speech into text and uses spoken instructions to produce text for the user's current workflow.

## Settings UI direction

The Settings window keeps the native macOS Liquid Glass treatment. Use standard SwiftUI `NavigationSplitView`, sidebar `List`, grouped `Form`, and native controls so macOS 26 can provide Liquid Glass automatically; do not replace the shell with opaque custom panels or apply decorative glass to content groups.

The Settings sidebar is always visible and must not expose a collapse control. Its native divider remains resizable, with percentage-based minimum, midpoint, and maximum widths defined in `Whale/Sources/SettingsView.swift`. The History page uses percentage-based columns inside the detail pane so adding History does not push the Settings sidebar outside the window.

## Language

**Transcription**:
The conversion of captured speech into text.
_Avoid_: Model, speech processing

**Transcript**:
The text artifact produced by transcription and saved for later use.
_Avoid_: Transcription, when referring to the saved output

**Push-to-Talk**:
A capture mode that records while its shortcut is held, then transcribes and inserts the result when released.

**Transcript Mode**:
A capture mode that starts and stops on separate shortcut presses and saves the resulting transcript.
_Avoid_: Toggle Record, Toggle Recording

**Transcription model**:
A speech-recognition model that produces a transcription.
_Avoid_: Model

**Smart Formatting**:
An optional rewrite, applied after transcription, that turns spoken numbers, money, dates, and times in a transcript into the written forms a reader expects.
_Avoid_: ITN, inverse text normalization, normalization

**Dictation**:
A user intent in which speech becomes text without reasoning over external user content.
_Avoid_: Basic mode, transcription operation

**AI Action**:
A user intent in which a spoken instruction and available context are processed to produce a result.
_Avoid_: Command mode, operation

**Context Snapshot**:
The external inputs associated with an AI Action, fixed at the moment the action begins so later changes do not alter its meaning.
_Avoid_: Current context, live context

**Context Input**:
A labeled piece of user content within a Context Snapshot, such as selected content or clipboard content, that an AI Action may use.
_Avoid_: Attachment, source

**Agent Run**:
The execution of an AI Action, potentially involving multiple model turns and Tool uses, that ends in a user-facing result.
_Avoid_: Backend request, operation

**Tool**:
A constrained capability that may be invoked during an Agent Run.
_Avoid_: Function, integration

**History**:
The persistent local log of Dictations and AI Actions, including their inputs, outcomes, and any Action Results, retained until the user deletes them but never included automatically in a later Agent Run.
_Avoid_: Action History, memory, conversation

**History Entry**:
A retained Dictation or AI Action within History.
_Avoid_: Preview, message

**Action Result**:
The final user-facing text produced by an AI Action and made available for insertion, copying, and later review.
_Avoid_: Response, assistant message

**Insertion Target**:
The focused destination that can receive a Dictation or Action Result, including conventional text fields and compatible editors such as terminal input.
_Avoid_: HUD anchor, input field

**HUD Anchor**:
A trustworthy on-screen location associated with an Insertion Target where Whale can place its recording HUD. For terminal input, the caret or prompt location qualifies; the full terminal viewport does not.
_Avoid_: Insertion Target

**HUD**:
Whale’s non-interactive floating feedback surface for recording, processing, delivery guidance, and outcomes.
_Avoid_: Indicator window, overlay
