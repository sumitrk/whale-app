# Log: Step 02 — Swift Menu Bar Shell

## Status: COMPLETE ✅

## What Was Built
- `project.yml` — XcodeGen config (menu bar app, macOS 13+, no sandbox, automatic signing)
- `TranscribeMeetingApp.swift` — @main entry, MenuBarExtra scene with mic/record icon
- `AppState.swift` — central @MainActor state (starting/ready/recording/error)
- `PythonServer.swift` — spawns server/server.py as subprocess, polls /health every 500ms
- `MenuBarView.swift` — dropdown with status label, Start Recording stub, Open Meetings Folder, Settings, Quit
- `Info.plist` — LSUIElement=true (hides Dock icon), mic + screen recording descriptions
- `TranscribeMeeting.entitlements` — network client + mic + no sandbox

## What Worked
- Mic icon appears in menu bar ✅
- Python server auto-starts when app launches ✅
- Status transitions: "Starting server..." → "Ready" ✅
- Dropdown menu shows all items correctly ✅
- Server stops when app quits ✅

## Issues Encountered & Fixed
- **Xcode keychain prompt**: Asked for macOS login password to access Apple Development cert — normal first-time behaviour, enter Mac login password and click "Always Allow"
- **"Connection refused" noise in Xcode console**: Looked alarming but was just the normal polling logs during the ~1s window before the server booted. Not an error.
- **Server stderr was /dev/null**: If the server crashed on startup we'd have no idea why. Fixed by redirecting stdout/stderr to `/tmp/transcribemeeting-server.log`
- **Port conflict on relaunch**: If a server from a previous session was still running on 8765, spawning a new one would fail silently. Fixed by checking `isHealthy()` first and reusing the existing server
- **Entitlements file wiped by Xcode**: Xcode overwrote our entitlements to `<dict/>` (empty). Not a problem in practice since we have no sandbox enabled — localhost connections work regardless

## Test Results
```
Menu bar icon: ✅ mic icon visible
Status:        ✅ "Ready" after ~1s
Dropdown:      ✅ Start Recording / Open Meetings Folder / Settings / Quit
Server health: ✅ curl http://localhost:8765/health → {"status":"ok"}
Server log:    ✅ /tmp/transcribemeeting-server.log shows clean startup
```

## Next Step
`plans/step-03-audio-capture.md`
