# Step 2: Swift Xcode Project + Menu Bar Shell

## Goal
Create a bare-bones SwiftUI menu bar app that appears in the menu bar, auto-starts the Python FastAPI server as a subprocess, and waits for it to be healthy before marking itself ready. No recording yet — just the shell.

## What Is Usable After This Step
- App icon appears in the menu bar
- Right-clicking shows: Status / Settings (stub) / Quit
- Python server starts automatically in background when app launches
- App shows "Starting…" until `/health` responds, then "Ready"
- Quitting the app also kills the Python server

---

## Xcode Project Setup

### 1. Create the project
1. Open Xcode → New Project → macOS → App
2. Product Name: `TranscribeMeeting`
3. Bundle Identifier: `com.sumitrk.transcribe-meeting`
4. Interface: SwiftUI
5. Language: Swift
6. **Uncheck**: "Include Tests" for now
7. Save inside the repo root as `TranscribeMeeting/`

### 2. Configure as menu bar app
In `Info.plist` (or via target settings):
```xml
<key>LSUIElement</key>
<true/>
```
This hides the Dock icon and makes it a menu bar-only app.

### 3. Remove the default window
Delete `ContentView.swift`. We won't use a main window — everything is menu bar.

---

## Files to Create

### `TranscribeMeetingApp.swift`
```swift
import SwiftUI

@main
struct TranscribeMeetingApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.isRecording ? "record.circle.fill" : "mic")
                .foregroundColor(appState.isRecording ? .red : .primary)
        }
        .menuBarExtraStyle(.menu)
    }
}
```

---

### `AppState.swift`
Central state object shared across the app.

```swift
import Foundation
import Combine

enum AppStatus {
    case starting
    case ready
    case recording
    case processing
    case error(String)
}

class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
    @Published var isRecording = false
    @Published var lastMeetingPath: String? = nil

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }
}
```

---

### `MenuBarView.swift`
The dropdown that appears when user clicks the menu bar icon.

```swift
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            // Status indicator
            Text(statusLabel)
                .foregroundColor(.secondary)
                .disabled(true)

            Divider()

            // Start / Stop recording
            Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
                // Wired in Step 3
            }
            .disabled(!appState.isReady)
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            if let path = appState.lastMeetingPath {
                Button("Open Last Meeting") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }

            Button("Open Meetings Folder") {
                // Uses output folder from settings — hardcoded for now
                let url = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Documents/Meetings")
                NSWorkspace.shared.open(url)
            }

            Divider()

            Button("Settings…") {
                // Wired in Step 6
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var statusLabel: String {
        switch appState.status {
        case .starting:    return "⧗ Starting server..."
        case .ready:       return "● Ready"
        case .recording:   return "🔴 Recording..."
        case .processing:  return "⧗ Processing..."
        case .error(let msg): return "⚠️ \(msg)"
        }
    }
}
```

---

### `PythonServer.swift`
Manages the Python subprocess lifecycle.

```swift
import Foundation

class PythonServer: ObservableObject {
    private var process: Process?
    private let port = 8765
    private let healthURL = URL(string: "http://127.0.0.1:8765/health")!

    // Start the Python FastAPI server bundled in the app
    func start() async throws {
        // Find bundled Python and server script
        guard let serverScript = Bundle.main.path(forResource: "server", ofType: "py", inDirectory: "scripts"),
              let pythonPath = Bundle.main.path(forResource: "python3", ofType: nil, inDirectory: "python-runtime/bin")
        else {
            // During development: use system Python
            try startWithSystemPython()
            return
        }
        try startProcess(python: pythonPath, script: serverScript)
    }

    private func startWithSystemPython() throws {
        // Dev mode: find server.py relative to the project
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")

        // Find server.py — look next to the binary during development
        let serverPath = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("server/server.py")
            .path

        proc.arguments = [serverPath]
        proc.currentDirectoryURL = URL(fileURLWithPath: serverPath).deletingLastPathComponent()

        // Suppress server output (or redirect to a log file)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        try proc.run()
        self.process = proc
    }

    private func startProcess(python: String, script: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        self.process = proc
    }

    // Poll /health until the server is up (max 15 seconds)
    func waitUntilHealthy() async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await isHealthy() { return }
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
        }
        throw NSError(domain: "PythonServer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Server failed to start in 15 seconds"])
    }

    func isHealthy() async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}
```

---

### Wire server startup into `TranscribeMeetingApp.swift`

Update `AppState` to hold and start the server:

```swift
class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
    @Published var isRecording = false
    @Published var lastMeetingPath: String? = nil

    let server = PythonServer()

    init() {
        Task {
            do {
                try await server.start()
                try await server.waitUntilHealthy()
                await MainActor.run { self.status = .ready }
            } catch {
                await MainActor.run {
                    self.status = .error("Server failed: \(error.localizedDescription)")
                }
            }
        }
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }
}
```

---

## Build & Run (Development)

1. In Xcode, build and run (`⌘R`)
2. App should appear in menu bar (mic icon)
3. Status should show "⧗ Starting server..." then switch to "● Ready" within ~2 seconds
4. Open a terminal and verify:
```bash
curl http://localhost:8765/health
# {"status":"ok","version":"1.0.0"}
```
5. Quit the app from the menu → curl should fail (server stopped)

---

## Tests

### Test 1: Menu bar icon appears
- Build and run → mic icon visible in menu bar ✅

### Test 2: Server starts automatically
```bash
curl http://localhost:8765/health
# Expected: {"status":"ok","version":"1.0.0"}
```

### Test 3: Status transitions
- Click menu bar icon immediately after launch → should show "⧗ Starting server..."
- Wait ~2 seconds → should show "● Ready" ✅

### Test 4: Server stops on quit
```bash
# While app running:
curl http://localhost:8765/health   # 200 OK
# Quit app from menu
curl http://localhost:8765/health   # Connection refused
```

---

## Done When

- [ ] App appears as mic icon in menu bar
- [ ] Right-click shows status + menu items
- [ ] `curl localhost:8765/health` responds while app is running
- [ ] Server stops when app quits
- [ ] Status label shows "Starting…" → "Ready" on launch

---

**Next:** `plans/step-03-audio-capture.md`
