# Whale

Whale turns captured speech into text and uses spoken instructions to produce text for the user's current workflow.

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

**AI Cleanup**:
Optional refinement of a transcription's wording and formatting without changing its intended meaning.
_Avoid_: Post-Processing

**Cleanup model**:
A language model that performs AI Cleanup.
_Avoid_: Model, local AI model

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

**Action History**:
A persistent local log of completed and failed AI Actions, including their Context Snapshots and any Action Results, retained until the user deletes them but never included automatically in a later Agent Run.
_Avoid_: Memory, conversation

**Action Result**:
The final user-facing text produced by an AI Action and made available for insertion, copying, and later review.
_Avoid_: Response, assistant message
