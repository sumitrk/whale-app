# V1 Standalone macOS App — Build Plan

## What We're Building

A native macOS menu bar app that:
- Runs silently in the background at login
- Starts/stops recording with a global hotkey (⌘⇧R)
- Captures system audio (Google Meet, Zoom, etc.) + microphone via ScreenCaptureKit
- Transcribes with MLX Whisper, summarises with Claude
- Saves a markdown file and sends a macOS notification

No terminal. No BlackHole. No manual audio routing. Just install and press a key.

---

## Architecture

```
TranscribeMeeting.app (SwiftUI)
├── Menu bar icon (toggle recording)
├── Global hotkey listener
├── ScreenCaptureKit (system audio)
├── AVCaptureDevice (microphone)
├── Onboarding window
├── Settings window
└── HTTP client → localhost:8765

Python FastAPI server (bundled subprocess)
├── POST /transcribe   → MLX Whisper
├── POST /summarise    → Claude API
├── GET  /health       → status check
└── GET  /models       → model list + download
```

---

## 7 Steps — Each Independently Testable

| Step | What's Built | Usable After |
|------|-------------|--------------|
| 1 | Python FastAPI server | `curl localhost:8765/health` works |
| 2 | Swift Xcode project + menu bar shell | App in menu bar, Python server auto-starts |
| 3 | Audio capture (ScreenCaptureKit + mic) | Record → WAV → transcription in console |
| 4 | Full pipeline + notifications | Press hotkey twice → markdown file saved |
| 5 | Onboarding + permissions flow | Fresh install → guided setup → fully working |
| 6 | Settings window | Hotkey, model, folder, API key all configurable |
| 7 | Packaging + distribution | `brew install --cask transcribe-meeting` works |

---

## Key Tech Decisions

- **Audio**: ScreenCaptureKit (no BlackHole needed, volume keys work)
- **Python bridge**: FastAPI on localhost:8765, auto-started by Swift
- **Python bundling**: `python-build-standalone` embedded in .app
- **Hotkey**: `CGEventTap` (no extra Swift dependencies)
- **Login item**: `SMAppService.mainApp.register()`
- **Distribution**: Signed DMG → GitHub Releases + Homebrew Cask

---

## Folder Structure (end state)

```
transcribe-meeting/
├── TranscribeMeeting/           ← Xcode Swift project
│   ├── TranscribeMeetingApp.swift
│   ├── MenuBarController.swift
│   ├── AudioRecorder.swift
│   ├── PythonBridge.swift
│   ├── OnboardingView.swift
│   ├── SettingsView.swift
│   └── NotificationManager.swift
├── server/                      ← Python FastAPI server
│   ├── server.py
│   ├── transcriber.py
│   ├── llm.py
│   ├── output.py
│   └── requirements.txt
├── scripts/
│   └── build.sh                 ← build + notarize script
└── docs/archive/specifications/v1-standalone-macos-app/
    ├── spec.md
    ├── plans/
    └── log/
```

---

## Prerequisites Before Starting

- Xcode 15+ installed
- Apple Developer account (free tier works for local dev; paid needed for notarization)
- Python 3.11 available (`brew install python@3.11`)
- Existing Python scripts from V0 (transcriber.py, llm.py, output.py)

---

**Start with:** `plans/step-01-fastapi-server.md`
