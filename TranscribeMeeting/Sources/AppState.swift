import AppKit
import CoreGraphics
import Foundation

enum AppStatus: Equatable {
    case starting
    case ready
    case recording
    case transcribing
    case summarising
    case error(String)
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
    @Published var isRecording = false
    @Published var lastMeetingPath: String? = nil

    let server   = PythonServer()
    let recorder = AudioRecorder()
    let client   = TranscribeClient()
    let hotkey   = HotkeyManager()

    var whisperModel: String = "mlx-community/whisper-large-v3-turbo"

    /// API key stored in UserDefaults.
    /// Set once from Terminal: defaults write com.sumitrk.transcribe-meeting anthropicApiKey "sk-ant-..."
    /// The Settings window (step 6) will let you set it via UI instead.
    var anthropicApiKey: String {
        UserDefaults.standard.string(forKey: "anthropicApiKey") ?? ""
    }

    private var recordingStartedAt: Date?

    init() {
        Task { await startServer() }

        // ⌘⇧T — toggle recording
        hotkey.start { [weak self] in self?.toggleRecording() }

        // Fn (hold) — push-to-talk: start on press, stop on release
        hotkey.startPushToTalk(
            onPress: { [weak self] in
                guard let self, !self.isRecording else { return }
                Task { await self.startRecording() }
            },
            onRelease: { [weak self] in
                guard let self, self.isRecording else { return }
                Task { await self.stopRecording() }
            }
        )

        // Request Accessibility permission so we can auto-paste after transcription.
        // Without it we fall back to clipboard-only.
        requestAccessibilityIfNeeded()
    }

    var isReady: Bool { status == .ready }

    var statusLabel: String {
        switch status {
        case .starting:      return "Starting server…"
        case .ready:         return "Ready  (⌘⇧T or hold Fn)"
        case .recording:     return "Recording…  (⌘⇧T or release Fn)"
        case .transcribing:  return "Transcribing…"
        case .summarising:   return "Summarising…"
        case .error(let m):  return "Error: \(m)"
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    func startRecording() async {
        do {
            try await recorder.startRecording()
            isRecording = true
            status = .recording
            recordingStartedAt = Date()
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func stopRecording() async {
        let startedAt = recordingStartedAt ?? Date()
        isRecording = false
        status = .transcribing

        do {
            // 1. Stop capture → WAV file
            let wavURL = try await recorder.stopRecording()
            print("WAV saved: \(wavURL.path)")

            // 2. Whisper transcription
            let rawTranscript = try await client.transcribe(wavURL: wavURL, model: whisperModel)
            print("Transcript ready (\(rawTranscript.count) chars)")

            let duration = Int(Date().timeIntervalSince(startedAt) / 60)
            let mdURL = wavURL.deletingPathExtension().appendingPathExtension("md")

            // 3. Claude summarisation (skipped gracefully if no API key)
            let pasteText: String  // what goes into clipboard / gets pasted
            let md: String
            if anthropicApiKey.isEmpty {
                print("No API key — skipping summarisation")
                pasteText = rawTranscript
                md = buildMarkdown(date: startedAt, duration: duration,
                                   cleanedTranscript: rawTranscript, summary: nil)
            } else {
                status = .summarising
                let result = try await client.summarise(transcript: rawTranscript,
                                                        apiKey: anthropicApiKey)
                print("Summary ready")
                pasteText = result.cleaned_transcript
                md = buildMarkdown(date: startedAt, duration: duration,
                                   cleanedTranscript: result.cleaned_transcript,
                                   summary: result.summary)
            }

            // 4. Write markdown file
            try md.write(to: mdURL, atomically: true, encoding: .utf8)
            print("Saved: \(mdURL.path)")

            lastMeetingPath = mdURL.path
            status = .ready

            // 5. Copy transcript to clipboard + auto-paste into active input
            copyAndPaste(pasteText)

            // 6. Reveal in Finder
            NSWorkspace.shared.selectFile(mdURL.path, inFileViewerRootedAtPath: "")

        } catch {
            isRecording = false
            status = .error(error.localizedDescription)
            print("Recording error: \(error.localizedDescription)")
        }
    }

    // MARK: - Clipboard + paste

    /// Copies `text` to the system clipboard, then simulates ⌘V to paste it
    /// into whatever app/input is currently focused.
    ///
    /// Auto-paste requires Accessibility permission. If it hasn't been granted,
    /// the text is still on the clipboard so the user can paste manually.
    private func copyAndPaste(_ text: String) {
        // Always copy to clipboard — no permission needed
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("Copied to clipboard (\(text.count) chars)")

        guard AXIsProcessTrusted() else {
            print("Accessibility not granted — clipboard only (grant in System Settings > Privacy & Security > Accessibility)")
            return
        }

        // Simulate ⌘V into the currently focused app.
        // Our app is LSUIElement (no dock icon, never steals focus), so the
        // user's active window/input field remains focused throughout recording.
        let src  = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags   = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        print("Auto-pasted via ⌘V")
    }

    // MARK: - Accessibility

    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        // Shows the system prompt directing the user to System Settings > Accessibility
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - Markdown builder

    private func buildMarkdown(date: Date, duration: Int,
                               cleanedTranscript: String, summary: String?) -> String {
        var sections: [String] = [
            "# Meeting — \(formattedDate(date))",
            "**Duration:** ~\(max(1, duration)) min  |  **Model:** \(whisperModel)",
        ]

        if let summary {
            sections += ["", summary]
        }

        sections += [
            "",
            "## Transcript",
            "",
            cleanedTranscript,
        ]

        return sections.joined(separator: "\n")
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Server startup

    private func startServer() async {
        do {
            try await server.start()
            try await server.waitUntilHealthy()
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}
