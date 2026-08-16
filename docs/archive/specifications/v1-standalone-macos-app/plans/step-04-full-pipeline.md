# Step 4: Full Pipeline + Hotkey + Notifications

## Goal
Wire up the complete end-to-end loop: global hotkey → start recording → stop recording → transcribe → summarise → save markdown → macOS notification. This is the first time the full V1 experience works. No onboarding or settings UI yet — API key and output folder are hardcoded from environment/defaults.

## What Is Usable After This Step
Press `⌘⇧R` → recording starts (icon pulses red). Press `⌘⇧R` again → recording stops, transcription runs in background, markdown file appears in `~/Documents/Meetings`, macOS notification pops up saying "Meeting saved".

---

## Files to Create/Modify

### `HotkeyManager.swift`

Registers a global hotkey using `CGEventTap` (no external dependencies).

```swift
import Carbon
import Foundation

class HotkeyManager {
    private var eventTap: CFMachPort?
    var onHotkeyPressed: (() -> Void)?

    // Default: ⌘⇧R
    private var targetKeyCode: CGKeyCode = 15  // 'R'
    private var targetModifiers: CGEventFlags = [.maskCommand, .maskShift]

    func register() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            print("⚠️ Failed to create event tap — check Accessibility permissions")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func unregister() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            if keyCode == targetKeyCode && flags.contains(targetModifiers) {
                DispatchQueue.main.async { self.onHotkeyPressed?() }
                return nil  // Swallow the event
            }
        }
        return Unmanaged.passRetained(event)
    }

    // Update the hotkey (for Settings — Step 6)
    func update(keyCode: CGKeyCode, modifiers: CGEventFlags) {
        targetKeyCode = keyCode
        targetModifiers = modifiers
    }
}
```

> **Note**: `CGEventTap` requires Accessibility permission. In Step 5 (Onboarding), we'll add the permission check. For now, enable manually in System Settings → Privacy & Security → Accessibility → add Terminal or the app.

---

### `NotificationManager.swift`

```swift
import UserNotifications
import AppKit

class NotificationManager {
    static let shared = NotificationManager()

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyMeetingSaved(filePath: String) {
        let content = UNMutableNotificationContent()
        content.title = "Meeting saved"
        content.body = URL(fileURLWithPath: filePath).lastPathComponent
        content.sound = .default
        content.userInfo = ["filePath": filePath]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func notifyError(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription failed"
        content.body = message
        content.sound = .defaultCritical

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func notifyTranscriptSavedWithWarning(filePath: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcript saved (no summary)"
        content.body = "Claude API unavailable. Raw transcript saved."
        content.sound = .default
        content.userInfo = ["filePath": filePath]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
```

---

### `MeetingPipeline.swift`

Orchestrates: stop recording → transcribe → summarise → write markdown → notify.

```swift
import Foundation

class MeetingPipeline {
    let client: TranscribeClient
    let outputFolder: URL

    init(client: TranscribeClient, outputFolder: URL = defaultOutputFolder()) {
        self.client = client
        self.outputFolder = outputFolder
    }

    static func defaultOutputFolder() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = docs.appendingPathComponent("Meetings")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func run(wavURL: URL, startedAt: Date, apiKey: String, model: String) async {
        do {
            // 1. Transcribe
            let transcript = try await client.transcribe(
                wavURL: wavURL,
                model: model
            )

            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NotificationManager.shared.notifyError("No speech detected in recording.")
                return
            }

            // 2. Summarise (with graceful fallback)
            var cleanedTranscript = transcript
            var summary = "> ⚠️ Summary unavailable (Claude API error). Raw transcript below."
            var summaryFailed = false

            if !apiKey.isEmpty {
                do {
                    let result = try await client.summarise(transcript: transcript, apiKey: apiKey, model: "claude-sonnet-4-5")
                    cleanedTranscript = result.cleaned_transcript
                    summary = result.summary
                } catch {
                    print("Claude API error: \(error) — saving raw transcript")
                    summaryFailed = true
                }
            } else {
                summaryFailed = true
            }

            // 3. Write markdown
            let duration = Int(Date().timeIntervalSince(startedAt) / 60)
            let filePath = try writeMarkdown(
                transcript: cleanedTranscript,
                summary: summary,
                startedAt: startedAt,
                durationMinutes: max(1, duration)
            )

            // 4. Notify
            if summaryFailed {
                NotificationManager.shared.notifyTranscriptSavedWithWarning(filePath: filePath)
            } else {
                NotificationManager.shared.notifyMeetingSaved(filePath: filePath)
            }

        } catch {
            NotificationManager.shared.notifyError(error.localizedDescription)
        }

        // Cleanup temp WAV
        try? FileManager.default.removeItem(at: wavURL)
    }

    private func writeMarkdown(
        transcript: String,
        summary: String,
        startedAt: Date,
        durationMinutes: Int
    ) throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateStr = formatter.string(from: startedAt)

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "d MMM yyyy, h:mma"
        let displayDate = dayFormatter.string(from: startedAt)

        let content = """
        ---
        date: \(dateStr)
        duration: \(durationMinutes) min
        ---

        # Meeting — \(displayDate)

        ## Summary

        \(summary)

        ---

        ## Full Transcript

        \(transcript)
        """

        let safeDate = dateStr.replacingOccurrences(of: ":", with: "-")
        let filename = "\(safeDate) - Meeting.md"
        let fileURL = outputFolder.appendingPathComponent(filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }
}
```

---

### Update `AppState.swift` — wire everything together

```swift
class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
    @Published var isRecording = false
    @Published var lastMeetingPath: String? = nil

    let server = PythonServer()
    let recorder = AudioRecorder()
    let client = TranscribeClient()
    let hotkey = HotkeyManager()
    lazy var pipeline = MeetingPipeline(client: client)

    private var recordingStartedAt: Date?

    // Temporary: read API key from environment / UserDefaults
    var apiKey: String { ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "" }
    var whisperModel: String { "mlx-community/whisper-small-mlx" }

    init() {
        NotificationManager.shared.requestPermission()
        Task { await startServer() }

        hotkey.onHotkeyPressed = { [weak self] in
            self?.toggleRecording()
        }
        hotkey.register()
    }

    private func startServer() async {
        do {
            try await server.start()
            try await server.waitUntilHealthy()
            await MainActor.run { self.status = .ready }
        } catch {
            await MainActor.run { self.status = .error("Server failed to start") }
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        Task {
            do {
                try await recorder.startRecording()
                await MainActor.run {
                    self.isRecording = true
                    self.status = .recording
                    self.recordingStartedAt = Date()
                }
            } catch {
                await MainActor.run { self.status = .error(error.localizedDescription) }
            }
        }
    }

    private func stopRecording() {
        let startedAt = recordingStartedAt ?? Date()
        Task {
            do {
                let wavURL = try await recorder.stopRecording()
                await MainActor.run {
                    self.isRecording = false
                    self.status = .ready  // Return to idle immediately
                }
                // Run pipeline in background
                await pipeline.run(wavURL: wavURL, startedAt: startedAt,
                                   apiKey: apiKey, model: whisperModel)
            } catch {
                await MainActor.run {
                    self.isRecording = false
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }
}
```

---

### Update `MenuBarView.swift` — wire toggle button

```swift
Button(appState.isRecording ? "Stop Recording  ⌘⇧R" : "Start Recording  ⌘⇧R") {
    appState.toggleRecording()
}
.disabled(!appState.isReady && !appState.isRecording)
```

---

## Tests

### Test 1: Hotkey triggers recording
```
1. Build and run app
2. Press ⌘⇧R from any app
3. Menu bar icon → red pulsing dot
4. Press ⌘⇧R again → grey mic icon
5. Check Xcode console: "WAV saved to: /tmp/meeting-XXXX.wav"
```

### Test 2: Full pipeline
```
1. Start recording (⌘⇧R)
2. Say "Testing one two three, this is a meeting about Q2 planning"
3. Play a few seconds of any YouTube video
4. Stop recording (⌘⇧R)
5. Wait ~60-90 seconds (transcription + Claude)
6. macOS notification: "Meeting saved — 2025-03-18 15-00 - Meeting.md"
7. Open ~/Documents/Meetings/ → markdown file exists with summary + transcript
```

### Test 3: Claude failure fallback
```
1. Temporarily set apiKey = "" in AppState
2. Record and stop
3. Notification: "Transcript saved (no summary)"
4. Markdown file contains raw transcript with ⚠️ warning header
```

---

## Done When

- [ ] `⌘⇧R` starts and stops recording from any app
- [ ] Icon changes: grey mic → red dot → grey mic
- [ ] Markdown file saved to `~/Documents/Meetings/` after stopping
- [ ] macOS notification fires when file is saved
- [ ] Claude failure saves raw transcript with warning

---

**Next:** `plans/step-05-onboarding.md`
