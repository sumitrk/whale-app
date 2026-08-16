# Idea: VAD Processor & Formal TranscriptionPipeline Object

## Current State
The transcription pipeline is implicit — spread across AppState.stopRecording():
```
startRecording() → AudioRecorder buffers raw audio
stopRecording()  → send entire WAV → Whisper → paste
```
No silence detection. We send everything including silence to Whisper.

---

## Idea 1: VAD Processor (Voice Activity Detection)

### What it does
Detects actual speech segments in the audio and strips silence before
sending to Whisper. Only real speech gets transcribed.

### Why it matters
- Whisper hallucinates on silence (makes up words, repeats phrases)
- Smaller audio chunks = faster transcription
- Less memory buffered during long PTT holds
- Better accuracy overall

### Implementation
Use `silero-vad` (Python, ~1MB model) or Apple's built-in `SFSpeechRecognizer`
for silence detection as a pre-filter:

```python
# server.py — before sending to Whisper
from silero_vad import load_silero_vad, get_speech_timestamps
model = load_silero_vad()
speech_timestamps = get_speech_timestamps(audio, model)
# Only transcribe speech segments
```

Or on the Swift side using `AVAudioEngine` node tap to detect amplitude
drops and stop recording early (simpler, less accurate).

### Effort: ~1-2 days

---

## Idea 2: Formal TranscriptionPipeline Object

### What it does
Encapsulates the full pipeline as a clean, testable Swift object instead
of logic spread across AppState.

### Target design
```
AudioCapture → VADProcessor → TranscribeClient → PostProcessor → TextInsertion
```

```swift
class TranscriptionPipeline {
    func start(mode: RecordingMode) async
    func stop() async -> String  // returns final text

    // Configurable stages
    var vadEnabled: Bool
    var postProcessingEnabled: Bool
    var postProcessingProvider: PostProcessingProvider  // local Qwen, Anthropic, none
}
```

### Why it matters
- AppState becomes a thin coordinator (owns pipeline, reacts to state changes)
- Each stage is independently testable
- Easy to add/remove stages (e.g. plug in VAD, swap post-processor)
- Streaming becomes possible (emit partial results as each stage completes)

### Stages
1. **AudioCapture** — AVFoundation recording, mic + system audio
2. **VADProcessor** — strip silence, detect speech boundaries
3. **TranscribeClient** — Whisper/Parakeet via server (or WhisperKit natively)
4. **PostProcessor** — local Qwen, Anthropic API, or passthrough
5. **TextInsertion** — AX focus detection + CGEvent paste

### Effort: ~3-4 days (mostly refactoring, no new features)

---

## Suggested order of implementation
1. TranscriptionPipeline object (refactor first, makes everything else easier)
2. VAD Processor (plug into pipeline as a stage)
3. Native Swift architecture (optional, replaces TranscribeClient stage)
