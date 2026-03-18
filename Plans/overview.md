# macOS Meeting Transcriber — Build Plan Overview

Open-source Granola AI alternative. Local transcription on Apple Silicon, Claude for cleanup/summary, markdown output to Obsidian vault.

Spec: `Spec/macos-meeting-transcriber/spec.md`

---

## Build Strategy

Each step produces something **runnable and verifiable**. Don't move to the next step until the current step's test passes. An agent can read any individual step file and execute it independently.

---

## Steps at a Glance

| # | Step | Plan File | Test Command | Usable For |
|---|------|-----------|--------------|------------|
| 1 | Config + skeleton | `step-01-foundation.md` | `python main.py` | Validate your .env setup |
| 2 | Audio recording | `step-02-audio-recording.md` | `python main.py --record-test` | Record + play back audio |
| 3 | Transcription | `step-03-transcription.md` | `python main.py --transcribe-test` | WAV → text (offline) |
| 4 | LLM cleanup | `step-04-llm-cleanup.md` | `python main.py --llm-test` | Clean transcript + summary |
| 5 | Output file | `step-05-output.md` | `python main.py --output-test` | Save markdown note to vault |
| 6 | Hotkey wiring | `step-06-hotkey-integration.md` | `python main.py` | Full end-to-end meeting recorder |

---

## One-Time Setup (Do Before Step 1)

### 1. Install BlackHole

```bash
brew install blackhole-2ch
```

### 2. Create Aggregate Device in Audio MIDI Setup

Open **Audio MIDI Setup** (Spotlight search):

1. `+` → Create **Multi-Output Device**
   - Check: BlackHole 2ch + Built-in Output
   - Right-click → "Use This Device For Sound Output"

2. `+` → Create **Aggregate Device**
   - Check: BlackHole 2ch + Built-in Microphone
   - Name it: `MeetingAggregate`

### 3. Create vault folder

```bash
mkdir -p ~/Documents/Meetings
```

### 4. Copy .env template (after Step 1 creates it)

```bash
cp .env.example .env
# Edit .env and fill in VAULT_PATH and ANTHROPIC_API_KEY
```

### 5. Grant macOS permissions

| Permission | When prompted | Where |
|---|---|---|
| Microphone | First `--record-test` run | System Settings → Privacy → Microphone |
| Accessibility | First `python main.py` run | System Settings → Privacy → Accessibility |

---

## Tech Stack

| Concern | Choice | Why |
|---|---|---|
| Audio capture | `sounddevice` | Best Python binding for PortAudio |
| Audio format | 16kHz mono WAV | Optimal for Whisper |
| Transcription | `mlx-whisper` + `whisper-large-v3-mlx` | Fast, local, Apple Silicon |
| LLM | Claude (`claude-sonnet-4-6`) | Best structured output quality |
| Hotkey | `pynput` GlobalHotKeys | Pure Python, no extra tools |
| Config | `.env` + `python-dotenv` | Simple, git-safe |
| Output | Markdown + YAML frontmatter | Obsidian-compatible |

---

## File Map

```
transcribe-meetings/
├── main.py            ← entry point, grows each step
├── config.py          ← created in step 1
├── recorder.py        ← created in step 2
├── transcriber.py     ← created in step 3
├── llm.py             ← created in step 4
├── output.py          ← created in step 5
├── requirements.txt   ← created in step 1
├── .env               ← created by you (gitignored)
├── .env.example       ← created in step 1
├── .gitignore         ← created in step 1
├── Plans/
│   ├── overview.md           ← this file
│   ├── step-01-foundation.md
│   ├── step-02-audio-recording.md
│   ├── step-03-transcription.md
│   ├── step-04-llm-cleanup.md
│   ├── step-05-output.md
│   └── step-06-hotkey-integration.md
└── Spec/
    └── macos-meeting-transcriber/
        └── spec.md
```

---

## Common Issues

**"Audio device not found"**
→ Check `AUDIO_DEVICE_NAME` in `.env` matches exactly what Audio MIDI Setup shows

**"Whisper model downloading..."**
→ First run downloads the model. Use `WHISPER_MODEL=mlx-community/whisper-small-mlx` during dev

**"⌘⇧R doesn't do anything"**
→ Grant Accessibility permission: System Settings → Privacy & Security → Accessibility → Terminal

**"Claude returned invalid JSON"**
→ Already handled with code fence stripping. If it still fails, check `ANTHROPIC_API_KEY`

---

## After V0

See `Spec/macos-meeting-transcriber/spec.md` → Future Enhancements section:
- Speaker diarization
- ScreenCaptureKit (no BlackHole required)
- Menu bar app (SwiftUI wrapper)
- Local LLM via Ollama
