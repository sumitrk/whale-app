# Feature: macOS Meeting Transcriber (V0)

## Overview

A scrappy, open-source macOS CLI tool that records meeting audio (microphone + system audio via BlackHole), transcribes it locally using `mlx-whisper` on Apple Silicon, cleans the transcript and generates a meeting summary via the Claude API, and saves both as a single markdown file into a user-configured vault folder (Obsidian-compatible).

Think of it as an open-source Granola AI — fully local transcription, no subscription, your data stays on your machine.

---

## User Flow

1. User opens a terminal and runs `python main.py` once. The script validates config and starts a background global hotkey listener.
2. Terminal prints: `Listening... Press ⌘⇧R to start recording.`
3. User joins a Google Meet / Zoom / any meeting in any app.
4. User presses **⌘⇧R** → terminal prints `● Recording started` with a timestamp.
5. Audio is captured from an **aggregate device** (BlackHole + mic mixed together) and written to disk in **5-minute `.wav` chunks**.
6. User presses **⌘⇧R** again to stop → terminal prints `■ Recording stopped. Transcribing...`
7. All chunks are transcribed sequentially using `mlx-whisper`. Chunks are concatenated into a full raw transcript.
8. Terminal prints: `Transcription complete. Cleaning up with Claude...`
9. The full raw transcript is sent to Claude API in a single call. Claude returns:
   - A cleaned transcript (filler words removed, punctuation fixed)
   - A meeting summary (topics discussed, decisions made, open questions)
10. Terminal prompts: `Meeting title: ` — user types a short title and presses Enter.
11. Markdown file is written to the vault at `<vault_path>/YYYY-MM-DD HH-MM <title>.md`.
12. Terminal prints: `✓ Saved to <path>`. Script returns to listening state.

---

## Technical Architecture

### Stack
- **Language**: Python 3.11+
- **Audio capture**: `sounddevice` (reads from BlackHole aggregate device)
- **Audio format**: 16kHz mono WAV (optimal for Whisper)
- **Transcription**: `mlx-whisper` with `mlx-community/whisper-large-v3-mlx`
- **LLM**: Anthropic Claude API (`claude-sonnet-4-6`)
- **Hotkey**: `pynput` global keyboard listener
- **Config**: `.env` file in project root (loaded via `python-dotenv`)
- **Output**: Markdown file written to vault folder

### Project Structure

```
transcribe-meetings/
├── main.py                  # Entry point — starts listener loop
├── recorder.py              # Audio capture, chunked WAV writing
├── transcriber.py           # mlx-whisper transcription pipeline
├── llm.py                   # Claude API calls (clean + summarize)
├── output.py                # Markdown file assembly and saving
├── config.py                # Load + validate .env config
├── .env                     # User config (gitignored)
├── .env.example             # Template committed to repo
├── requirements.txt
└── Spec/
    └── macos-meeting-transcriber/
        └── spec.md
```

---

## Prerequisites & Setup

### BlackHole Installation (one-time, user does this)

```bash
brew install blackhole-2ch
```

Then in **Audio MIDI Setup** (macOS built-in app):
1. Click `+` → Create Multi-Output Device
2. Check both **BlackHole 2ch** and **Built-in Output** (or your headphones)
3. Set this Multi-Output Device as the system sound output

Then create an **Aggregate Device**:
1. Click `+` → Create Aggregate Device
2. Check both **BlackHole 2ch** and your **microphone input**
3. Name it `MeetingAggregate`

The script reads from `MeetingAggregate` — this captures both mic and system audio mixed.

---

## Configuration (.env)

```dotenv
# Path to your Obsidian vault or notes folder
VAULT_PATH=/Users/yourname/Documents/ObsidianVault/Meetings

# Anthropic API key
ANTHROPIC_API_KEY=sk-ant-...

# Name of the aggregate audio device (from Audio MIDI Setup)
AUDIO_DEVICE_NAME=MeetingAggregate

# Whisper model to use (default: mlx-community/whisper-large-v3-mlx)
WHISPER_MODEL=mlx-community/whisper-large-v3-mlx

# Chunk duration in seconds (default: 300 = 5 minutes)
CHUNK_DURATION_SECONDS=300
```

`.env.example` (committed to repo):
```dotenv
VAULT_PATH=
ANTHROPIC_API_KEY=
AUDIO_DEVICE_NAME=MeetingAggregate
WHISPER_MODEL=mlx-community/whisper-large-v3-mlx
CHUNK_DURATION_SECONDS=300
```

---

## Module Specifications

### `config.py`

Validates on startup. If any required key is missing or the vault path doesn't exist:
```
ERROR: VAULT_PATH is not set in .env
Fix: Add VAULT_PATH=/path/to/your/vault to your .env file
```
Exits with code 1 immediately.

```python
@dataclass
class Config:
    vault_path: Path
    anthropic_api_key: str
    audio_device_name: str
    whisper_model: str
    chunk_duration_seconds: int  # default: 300

def load_config() -> Config: ...
```

---

### `recorder.py`

- Uses `sounddevice` to open an input stream on the named aggregate device
- Sample rate: 16000 Hz, channels: 1 (mono), dtype: int16
- Writes audio to a temporary directory: `/tmp/transcribe-meetings/<session_id>/`
- File naming: `chunk_001.wav`, `chunk_002.wav`, etc.
- A new chunk file is started every `CHUNK_DURATION_SECONDS`
- On stop, flushes the final partial chunk (even if < 5 min)

```python
class Recorder:
    def start(self, session_id: str) -> None: ...
    def stop(self) -> list[Path]:  # returns list of chunk paths in order
        ...
```

---

### `transcriber.py`

- Iterates over chunk paths in order
- Calls `mlx_whisper.transcribe(str(chunk_path), path_or_hf_repo=model)` for each
- Concatenates `result["text"]` from each chunk with a single newline separator
- Returns the full raw transcript as a string
- Prints progress: `Transcribing chunk 1/4...`

```python
def transcribe_chunks(chunk_paths: list[Path], model: str) -> str: ...
```

---

### `llm.py`

Single API call after full transcription is complete.

**Prompt structure:**

```
System:
You are a meeting transcription assistant. You will receive a raw speech-to-text
transcript of a meeting and must return a JSON object with two fields:
- "cleaned_transcript": The transcript with filler words removed (uh, um, like, you know),
  run-on sentences broken up, and punctuation corrected. Preserve speaker meaning exactly.
- "summary": A structured markdown summary with the following sections:
  ## Topics Discussed
  ## Decisions Made
  ## Open Questions / Next Steps

Return only valid JSON. No commentary.

User:
<raw_transcript>
{transcript}
</raw_transcript>
```

**Response parsing:**

```python
@dataclass
class LLMResult:
    cleaned_transcript: str
    summary: str

def process_transcript(raw_transcript: str, api_key: str) -> LLMResult: ...
```

Uses `anthropic.Anthropic(api_key=...).messages.create(...)` with `claude-sonnet-4-6`.

---

### `output.py`

Assembles the final markdown file and writes it to vault.

**Markdown template:**

```markdown
---
date: YYYY-MM-DD
time: HH:MM
duration: ~N minutes
---

# <Meeting Title>

## Summary

{summary}

---

## Cleaned Transcript

{cleaned_transcript}
```

**Filename:** `YYYY-MM-DD HH-MM <title>.md`
Example: `2026-03-17 14-30 Product sync.md`

```python
def save_output(
    title: str,
    started_at: datetime,
    duration_minutes: int,
    result: LLMResult,
    vault_path: Path,
) -> Path: ...
```

---

### `main.py`

```
1. load_config() — validate and exit on error
2. Print: "Listening... Press ⌘⇧R to start recording."
3. Start pynput GlobalHotKeys listener:
   - ⌘⇧R → toggle_recording()
4. toggle_recording():
   - If not recording:
     - recorder.start(session_id=uuid4())
     - Print: "● Recording started [HH:MM:SS]"
     - started_at = datetime.now()
   - If recording:
     - chunks = recorder.stop()
     - Print: "■ Recording stopped. Transcribing..."
     - raw = transcribe_chunks(chunks, config.whisper_model)
     - Print: "Transcription complete. Cleaning up with Claude..."
     - result = process_transcript(raw, config.anthropic_api_key)
     - title = input("Meeting title: ").strip()
     - path = save_output(title, started_at, ..., result, config.vault_path)
     - Print: f"✓ Saved to {path}"
     - Clean up temp chunk files
     - Print: "Listening... Press ⌘⇧R to start recording."
```

---

## Audio Device Resolution

The script resolves the aggregate device index at startup using `sounddevice.query_devices()`:

```python
def find_device_index(name: str) -> int:
    for i, device in enumerate(sd.query_devices()):
        if name.lower() in device['name'].lower() and device['max_input_channels'] > 0:
            return i
    raise RuntimeError(f"Audio device '{name}' not found. Check Audio MIDI Setup.")
```

---

## Error Handling

| Scenario | Detection | Response |
|---|---|---|
| Missing `.env` key | `config.py` on startup | Print specific error + fix instructions, exit 1 |
| Vault path doesn't exist | `config.py` on startup | Print error + `mkdir` suggestion, exit 1 |
| Audio device not found | `recorder.py` on start | Print device list + fix instructions, exit 1 |
| mlx-whisper model download | First run | `mlx-whisper` downloads automatically, print progress |
| Claude API error | `llm.py` | Print error, offer to save raw transcript only |
| Keyboard interrupt (Ctrl+C) | `main.py` | If recording: stop, save raw transcript, exit |

---

## Dependencies

```
# requirements.txt
sounddevice
numpy
scipy          # for WAV writing
mlx-whisper
anthropic
pynput
python-dotenv
```

Install:
```bash
pip install -r requirements.txt
```

> **Note:** `mlx-whisper` requires Apple Silicon (M1/M2/M3/M4). Will not run on Intel Macs.
> On first run, the Whisper model (~3GB) is auto-downloaded from HuggingFace.
> `pynput` requires **Accessibility** permission in System Settings → Privacy & Security → Accessibility.

---

## macOS Permissions Required

| Permission | Why | How to grant |
|---|---|---|
| Microphone | Capture mic input | System Settings → Privacy → Microphone → Terminal (or your app) |
| Accessibility | `pynput` global hotkey | System Settings → Privacy → Accessibility → Terminal |

---

## Output Example

File: `~/Documents/Vault/Meetings/2026-03-17 14-30 Product sync.md`

```markdown
---
date: 2026-03-17
time: 14:30
duration: ~23 minutes
---

# Product sync

## Summary

## Topics Discussed
- Q2 roadmap priorities: focus on onboarding funnel and API v2
- Engineering capacity concerns for April sprint
- Design review process for new dashboard

## Decisions Made
- Ship onboarding v2 before end of March
- API v2 will be behind a feature flag initially

## Open Questions / Next Steps
- [ ] Alice to share wireframes by Friday
- [ ] Bob to estimate API v2 effort by EOD

---

## Cleaned Transcript

Alice: Let's start with the Q2 roadmap. I think onboarding needs to be the top priority.

Bob: Agreed. We also need to talk about engineering capacity for April...
```

---

## Success Criteria

- [ ] `python main.py` validates config and exits with a clear message if anything is wrong
- [ ] Pressing ⌘⇧R starts recording; pressing it again stops recording
- [ ] Audio is captured from both mic and system audio via the aggregate device
- [ ] 5-minute chunked WAV files appear in `/tmp/transcribe-meetings/` during recording
- [ ] All chunks are transcribed and concatenated into one raw transcript
- [ ] Claude returns a cleaned transcript and structured summary
- [ ] User is prompted for a meeting title after stopping
- [ ] Markdown file is saved to vault with correct filename and frontmatter
- [ ] Temp chunk files are deleted after successful save
- [ ] Script returns to listening state and can record another meeting without restarting

---

## Future Enhancements (Out of Scope for V0)

- Speaker diarization (identify "Me" vs "Them" in transcript)
- ScreenCaptureKit-based audio capture (no BlackHole required)
- SwiftUI or menu bar app wrapper
- Real-time partial transcription display
- Multiple output format support (Notion, Roam, plain text)
- Auto-detect meeting app start/stop
- Meeting title suggestion from transcript content
- Local LLM option via Ollama

---

**Ready for implementation!** Run `/guide Spec/macos-meeting-transcriber/spec.md` to generate a step-by-step tutorial.
