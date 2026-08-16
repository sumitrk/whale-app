# Feature: V1 Standalone macOS App

## Overview

Transform the CLI proof-of-concept into a distributable, native macOS menu bar app.
Users install it once, it runs silently in the background, and a global hotkey starts/stops
recording at any time — no terminal, no manual audio routing, no setup friction.

This is the Granola-style experience: invisible until needed, then a single keypress away.

---

## User Flow

### First Launch (Onboarding)
1. User installs via `brew install --cask transcribe-meeting` or downloads DMG
2. App opens a guided setup window (4 steps):
   - **Step 1 — Microphone**: Trigger macOS mic permission prompt. Explain why.
   - **Step 2 — Screen Recording**: Trigger macOS screen recording permission prompt (needed for ScreenCaptureKit system audio). Explain why.
   - **Step 3 — API Key**: Text field for Anthropic API key. Link to get one. Validate with a test call.
   - **Step 4 — Output Folder**: Folder picker, default `~/Documents/Meetings`. Show/create the folder.
3. App registers as a login item silently (via `SMAppService`). Togglable in Settings later.
4. App shrinks to menu bar. Onboarding window closes.

### Daily Use
1. User is in a meeting (Google Meet, Zoom, in-person, etc.)
2. Press global hotkey (default `⌘⇧R`) — recording starts immediately
3. Menu bar icon changes from grey mic 🎤 to pulsing red dot 🔴
4. Press hotkey again (or click icon) — recording stops
5. Icon returns to idle 🎤 immediately
6. Processing runs fully in background: transcribe → LLM cleanup → save markdown
7. macOS notification appears: "📝 Meeting saved — 2025-03-18 3:00pm.md" — click opens in Finder
8. If Claude fails: notification says "⚠️ Transcript saved (summary unavailable)"

### Settings
- Accessed via right-click menu → Settings… or click during idle
- User can change: hotkey, model, output folder, API key, Claude model, toggle LLM step, launch at login

---

## Technical Architecture

### App Structure

```
TranscribeMeeting.app/
├── Contents/
│   ├── MacOS/
│   │   └── TranscribeMeeting          ← Swift binary
│   ├── Frameworks/
│   │   └── python-runtime/            ← Bundled Python 3.11 (via python-build-standalone)
│   └── Resources/
│       ├── scripts/
│       │   ├── server.py              ← FastAPI server entry point
│       │   ├── transcriber.py
│       │   ├── llm.py
│       │   └── output.py
│       └── assets/
│           ├── mic-idle.png
│           └── mic-recording.png
```

### Swift Layer (UI + Audio + Orchestration)
- **Framework**: SwiftUI + AppKit
- **Menu bar**: `MenuBarExtra` (macOS 13+) with `NSStatusItem` fallback
- **Audio capture**: `ScreenCaptureKit` (system audio) + `AVCaptureDevice` (microphone)
- **Hotkey**: `MASShortcut` or custom `CGEventTap` for global keyboard shortcut registration
- **Settings storage**: `UserDefaults` / `@AppStorage`
- **Login item**: `SMAppService.mainApp.register()`
- **Notifications**: `UserNotifications` framework
- **IPC to Python**: HTTP calls to `localhost:8765` (FastAPI)

### Python Layer (Transcription + LLM)
- **Framework**: FastAPI + uvicorn
- **Endpoints**:
  - `POST /transcribe` — receives WAV file path, returns transcript text
  - `POST /summarise` — receives raw transcript, returns cleaned + summary JSON
  - `GET /health` — health check, returns `{"status": "ok"}`
- **Started by**: Swift launches Python subprocess on app start, waits for `/health` to respond
- **Bundled runtime**: `python-build-standalone` embedded in `.app/Contents/Frameworks/`
- **Model cache**: `~/Library/Application Support/TranscribeMeeting/models/`

### Audio Pipeline (Swift-side)
```
ScreenCaptureKit          AVCaptureDevice
(system audio)      +     (microphone)
       ↓                       ↓
   PCM float32            PCM float32
       ↓                       ↓
       └──────── mix ──────────┘
                  ↓
           write to WAV
       (16kHz, mono, int16)
                  ↓
          POST /transcribe
```

---

## API — Python FastAPI Server

### `POST /transcribe`
Swift calls this after recording stops.

**Request** (multipart form):
```
file: <WAV file binary>
model: "mlx-community/whisper-small-mlx"   (from settings)
```

**Response**:
```json
{
  "transcript": "So today we need to talk about...",
  "duration_seconds": 183,
  "chunks_processed": 2
}
```

**Error**:
```json
{
  "error": "model_not_found",
  "message": "Model not downloaded yet",
  "download_required": true,
  "model_id": "mlx-community/whisper-small-mlx"
}
```

---

### `POST /summarise`
**Request**:
```json
{
  "transcript": "So today we need to talk about...",
  "api_key": "sk-ant-...",
  "model": "claude-sonnet-4-5"
}
```

**Response**:
```json
{
  "cleaned_transcript": "Today's focus was the Q2 roadmap...",
  "summary": "## Topics Discussed\n- Q2 roadmap\n..."
}
```

**Error**:
```json
{
  "error": "api_key_invalid",
  "message": "Anthropic API key rejected"
}
```

---

### `GET /health`
**Response**:
```json
{ "status": "ok", "version": "1.0.0" }
```

---

### `GET /models`
**Response**:
```json
{
  "available": [
    {
      "id": "mlx-community/whisper-tiny-mlx",
      "label": "Tiny",
      "size_mb": 40,
      "downloaded": true
    },
    {
      "id": "mlx-community/whisper-small-mlx",
      "label": "Small",
      "size_mb": 150,
      "downloaded": false
    }
  ]
}
```

---

## UI/UX Specifications

### Menu Bar Icon

| State | Icon | Behaviour |
|---|---|---|
| Idle | 🎤 grey mic | Click → start recording |
| Recording | 🔴 pulsing red dot | Click → stop recording |
| Processing | ⧗ spinner | Click → show processing popover |
| Error | ⚠️ yellow | Click → show error popover |

**Right-click / secondary click menu** (always available):
```
● Recording (4:23)          ← dynamic status
─────────────────
Stop Recording              ← or "Start Recording" if idle
─────────────────
Open Meetings Folder
─────────────────
Settings…
─────────────────
Quit
```

---

### Onboarding Window

4-step SwiftUI wizard. Each step:
- Large icon + short title + one-sentence explanation
- Single CTA button ("Grant Access →", "Continue →", "Done →")
- Progress dots at bottom (●●○○)
- Cannot advance without completing the step

```
Step 1: Microphone
Step 2: Screen Recording
Step 3: Anthropic API Key [text field + "Test" button]
Step 4: Output Folder [path + Browse button]
```

---

### Settings Window

Tabbed SwiftUI window (`⌘,` to open):

**General tab**:
- Launch at login: toggle (default ON)
- Global shortcut: key recorder (default ⌘⇧R)
- Output folder: path field + Browse button

**Transcription tab**:
- Model: dropdown (Tiny / Small / Medium / Large-v3) + download status badge
- [Download] button if not cached

**AI Summary tab**:
- Enable AI summary: toggle
- Anthropic API key: secure text field + [Test] button
- Claude model: dropdown (claude-haiku-4-5 / claude-sonnet-4-5)

---

### Processing Popover (click icon during processing)

```
╭──────────────────────────╮
│ ⧗ Processing meeting...   │
│                           │
│ ✔ Recording complete      │
│ ▶ Transcribing...         │
│ ○ Summarising             │
│ ○ Saving                  │
╰──────────────────────────╯
```

---

## Output File Format

Filename: `YYYY-MM-DD HH:mm - Meeting.md` (auto-named, no user input needed)

```markdown
---
date: 2025-03-18
time: 15:00
duration: 12 min
model: whisper-small
---

# Meeting — 18 Mar 2025, 3:00pm

## Summary

### Topics Discussed
- Q2 roadmap priorities
- Onboarding v2 timeline

### Decisions
- Ship onboarding v2 before end of March

### Action Items
- [ ] Alice: share wireframes by Friday
- [ ] Bob: estimate API effort by EOD

---

## Full Transcript

So today we need to talk about the Q2 roadmap...
```

On Claude failure, the file is saved immediately after transcription with:
```markdown
> ⚠️ Summary unavailable (Claude API error). Raw transcript below.
```

---

## Error Handling

| Scenario | Detection | User sees |
|---|---|---|
| Mic permission denied | `AVAuthorizationStatus.denied` | Onboarding shows "Open System Settings" button |
| Screen recording denied | SCStream fails to start | Same — deeplink to Privacy settings |
| Python server won't start | `/health` times out after 10s | Alert: "Background service failed to start. Try relaunching." |
| Model not downloaded | `/transcribe` returns `model_not_found` | Popover with download progress bar |
| Claude API key invalid | `/summarise` returns 401 | Notification: "⚠️ Transcript saved. Check API key in Settings." |
| Claude rate limited / timeout | `/summarise` returns 429/timeout | Same fallback: save raw transcript, notify |
| No speech detected | Transcript is empty or whitespace | Notification: "No speech detected. Recording discarded." |
| Disk full | File write fails | Notification: "Could not save — disk full." |

---

## Permissions Required

Add to `Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>To record meeting audio</string>

<key>NSScreenCaptureDescription</key>  <!-- ScreenCaptureKit -->
<string>To capture system audio from meetings</string>
```

Entitlements:
- `com.apple.security.device.audio-input`
- `com.apple.security.device.microphone`

---

## Distribution

### Build
- Xcode project with `Release` scheme
- Sign with Apple Developer certificate (required for Gatekeeper / notarization)
- `xcodebuild archive` → `xcodebuild -exportArchive` → `.dmg`
- Notarize with `notarytool`

### GitHub Releases
```
github.com/sumitrk/transcribe-meeting/releases
  └── v1.0.0
      ├── TranscribeMeeting.dmg
      └── SHA256SUMS
```

### Homebrew Cask
```ruby
cask "transcribe-meeting" do
  version "1.0.0"
  sha256 "abc123..."
  url "https://github.com/sumitrk/transcribe-meeting/releases/download/v#{version}/TranscribeMeeting.dmg"
  name "Transcribe Meeting"
  desc "AI-powered meeting transcription for macOS"
  homepage "https://github.com/sumitrk/transcribe-meeting"
  app "TranscribeMeeting.app"
end
```

---

## Implementation Plan (Incremental Steps)

Each step produces something usable end-to-end:

### Step 1 — Python FastAPI Server
Convert existing Python scripts into a FastAPI server. Test with `curl`.
- `server.py` with `/health`, `/transcribe`, `/summarise`
- Keep all existing logic, just wrap in HTTP endpoints
- **Done when**: `curl localhost:8765/health` returns `{"status":"ok"}`

### Step 2 — Swift Xcode Project + Menu Bar Shell
Bare-bones SwiftUI menu bar app. No recording yet.
- `MenuBarExtra` with mic icon
- Launches Python server subprocess on start, polls `/health`
- Right-click menu: Settings (stub), Quit
- **Done when**: App appears in menu bar, Python server starts automatically

### Step 3 — Audio Capture in Swift (ScreenCaptureKit + Mic)
Record system audio + mic, mix, save as WAV, send to `/transcribe`.
- `SCStream` for system audio
- `AVCaptureSession` for mic
- Mix PCM buffers, write WAV to temp dir
- POST to `/transcribe`, log result
- **Done when**: Can record 30s, transcription appears in console

### Step 4 — Full Pipeline + Notifications
Wire up the full loop: record → transcribe → summarise → save → notify.
- POST to `/summarise`, write markdown to output folder
- `UserNotifications` for completion/error
- Menu bar state machine: idle → recording → processing → idle
- **Done when**: Press hotkey twice, markdown file appears in `~/Documents/Meetings`

### Step 5 — Onboarding + Permissions Flow
4-step guided onboarding window.
- SwiftUI `WindowGroup` for onboarding
- `AVCaptureDevice.requestAccess` for mic
- `SCShareableContent` permission check for screen recording
- Store completion flag in `UserDefaults`
- **Done when**: Fresh install triggers onboarding, permissions granted, app usable

### Step 6 — Settings Window
Full settings UI.
- Tab view: General / Transcription / AI Summary
- `SMAppService` for login item
- `MASShortcut` or `CGEventTap` for custom hotkey
- Model download with progress (stream from `/models/download`)
- **Done when**: Can change hotkey, model, folder, API key from UI

### Step 7 — Packaging + Distribution
Build, sign, notarize, release.
- Xcode archive + export DMG
- `notarytool` notarization
- GitHub Release + Homebrew Cask PR
- **Done when**: `brew install --cask transcribe-meeting` works on a clean Mac

---

## Dependencies

### Swift (via Swift Package Manager)
```swift
// Hotkey registration
.package(url: "https://github.com/nicklockwood/SwiftFormat", ...)
// Or use native CGEventTap (no dependency)
```

### Python (existing + additions)
```bash
pip install fastapi uvicorn python-multipart
# Existing: mlx-whisper, anthropic, scipy, sounddevice
```

---

## Success Criteria

The feature is complete when:

1. ✅ `brew install --cask transcribe-meeting` works on a clean Mac
2. ✅ Onboarding completes in under 2 minutes with no terminal required
3. ✅ Global hotkey starts/stops recording from any app
4. ✅ System audio (Google Meet etc.) + microphone both captured via ScreenCaptureKit
5. ✅ Meeting markdown appears in output folder within 3 minutes of stopping
6. ✅ Claude failure gracefully saves raw transcript with warning note
7. ✅ App survives reboot and hotkey still works (login item)
8. ✅ Model download shows progress and survives cancellation

---

## Out of Scope for V1

- Windows / Linux support
- Automatic meeting detection (starts recording when Zoom opens)
- Speaker diarisation (who said what)
- In-app meeting viewer / history browser
- Real-time transcription display during recording
- iCloud sync of meeting notes
- Local LLM option (no API key needed)

---

*Ready for implementation. Work through Steps 1–7 in order — each step is independently testable and usable.*
