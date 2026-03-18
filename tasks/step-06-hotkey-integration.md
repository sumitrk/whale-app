# Task: Step 6 — Global Hotkey Integration

## Status: COMPLETE ✅ (code written, needs live test with BlackHole)

## What Was Built
Full production `main.py` with:
- `pynput.keyboard.GlobalHotKeys({"<cmd>+<shift>+r": toggle_recording})` listener
- `toggle_recording()` — state machine: starts or stops recording based on current state
- `_run_pipeline()` — full pipeline: transcribe chunks → Claude → prompt for title → save → cleanup
- `_sigint_handler()` — graceful Ctrl+C: if recording, offers to save raw transcript
- `_prompt()` — reads user input from stdin (works from non-main thread on macOS)
- All `--*-test` flags preserved for debugging

## What Worked
- `main.py` imports cleanly (all modules resolve)
- All test flags (`--record-test`, `--transcribe-test`, `--llm-test`, `--output-test`) work
- `pynput` installed: `pynput==1.8.1` with pyobjc dependencies

## Pending: Live End-to-End Test
The full hotkey flow requires:
1. **BlackHole installed** (`brew install blackhole-2ch`)
2. **Aggregate Device created** in Audio MIDI Setup named `MeetingAggregate`
3. **Accessibility permission** granted to Terminal in System Settings

Until BlackHole is set up, `python3 main.py` will fail at device detection:
```
ERROR: Audio device 'MeetingAggregate' not found.
Available input devices:
  [0] MacBook Pro Microphone
  [2] iPhone Microphone
```

## How to Finish Setup and Test

### Install BlackHole
```bash
brew install blackhole-2ch
```

### Create Aggregate Device
1. Open Audio MIDI Setup (Spotlight)
2. `+` → Create Multi-Output Device
   - Check: BlackHole 2ch + Built-in Output
   - Right-click → "Use This Device For Sound Output"
3. `+` → Create Aggregate Device
   - Check: BlackHole 2ch + Built-in Microphone
   - Name it: `MeetingAggregate`

### Grant Accessibility Permission
System Settings → Privacy & Security → Accessibility → enable Terminal

### Run Full Test
```bash
python3 main.py
# Press ⌘⇧R → start recording
# Join a meeting, speak
# Press ⌘⇧R → stop
# Type meeting title
# Check ~/Downloads/Meetings/ for the markdown file
```

## Temporary Workaround (Without BlackHole)
Change `.env`:
```
AUDIO_DEVICE_NAME=MacBook Pro Microphone
```
This captures only mic audio (no system audio). Good for testing the full pipeline.

## Notes on Threading
- Hotkey callback runs on pynput's background thread
- `input()` / `sys.stdin.readline()` called from that thread — works on macOS terminal
- This blocks the hotkey listener during transcription + Claude call — correct behavior
  (you don't want a second hotkey press while processing)

## All Files Created Summary
```
transcribe-meetings/
├── main.py          ← full production entry point
├── config.py        ← .env validation
├── recorder.py      ← sounddevice chunked WAV recording
├── transcriber.py   ← mlx-whisper transcription
├── llm.py           ← Claude API cleanup + summary
├── output.py        ← markdown file assembly
├── requirements.txt
├── .env.example
├── .gitignore
├── Plans/           ← 6 step plan files
└── tasks/           ← this folder (progress logs)
```
