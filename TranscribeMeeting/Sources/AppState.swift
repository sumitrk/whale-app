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

/// Tracks how the current recording was triggered.
fileprivate enum RecordingMode {
    case markdown   // ⌘⇧T: Whisper → Claude → .md file → Finder
    case paste      // Fn:   Whisper only → clipboard + auto-paste
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

    var anthropicApiKey: String {
        UserDefaults.standard.string(forKey: "anthropicApiKey") ?? ""
    }

    private var recordingStartedAt: Date?
    private var currentMode: RecordingMode = .markdown

    init() {
        Task { await startServer() }

        // ⌘⇧T — toggle: full markdown pipeline
        hotkey.start { [weak self] in self?.toggleMarkdown() }

        // Fn (hold) — push-to-talk: paste only, no markdown
        hotkey.startPushToTalk(
            onPress: { [weak self] in
                guard let self, !self.isRecording else { return }
                Task { await self.startRecording(mode: .paste) }
            },
            onRelease: { [weak self] in
                guard let self, self.isRecording else { return }
                Task { await self.stopRecording() }
            }
        )

        requestAccessibility()
    }

    var isReady: Bool { status == .ready }

    var statusLabel: String {
        switch status {
        case .starting:      return "Starting server…"
        case .ready:         return "Ready  (⌘⇧T to record | hold Fn to dictate)"
        case .recording:
            return currentMode == .paste
                ? "Dictating…  (release Fn to stop)"
                : "Recording…  (⌘⇧T to stop)"
        case .transcribing:  return "Transcribing…"
        case .summarising:   return "Summarising…"
        case .error(let m):  return "Error: \(m)"
        }
    }

    // MARK: - Toggle (⌘⇧T)

    func toggleMarkdown() {
        if isRecording && currentMode == .markdown {
            Task { await stopRecording() }
        } else if !isRecording {
            Task { await startRecording(mode: .markdown) }
        }
        // ignore ⌘⇧T while in PTT mode
    }

    // MARK: - Recording core

    fileprivate func startRecording(mode: RecordingMode) async {
        do {
            currentMode = mode
            try await recorder.startRecording()
            isRecording = true
            status = .recording
            recordingStartedAt = Date()
            playSound("Tink")  // start cue
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func stopRecording() async {
        let startedAt = recordingStartedAt ?? Date()
        let mode = currentMode
        isRecording = false
        status = .transcribing

        do {
            let wavURL = try await recorder.stopRecording()
            print("WAV saved: \(wavURL.path)")

            let rawTranscript = try await client.transcribe(wavURL: wavURL, model: whisperModel)
            print("Transcript ready (\(rawTranscript.count) chars)")

            switch mode {

            case .paste:
                // PTT: just paste the raw transcript, no markdown file
                status = .ready
                playSound("Glass")  // done cue — transcription complete
                copyAndPaste(rawTranscript)
                // Delete the WAV — nothing to keep
                try? FileManager.default.removeItem(at: wavURL)

            case .markdown:
                // Toggle: full pipeline — Claude → .md → Finder
                let duration = Int(Date().timeIntervalSince(startedAt) / 60)
                let mdURL = wavURL.deletingPathExtension().appendingPathExtension("md")

                let md: String
                if anthropicApiKey.isEmpty {
                    print("No API key — skipping summarisation")
                    md = buildMarkdown(date: startedAt, duration: duration,
                                       cleanedTranscript: rawTranscript, summary: nil)
                } else {
                    status = .summarising
                    let result = try await client.summarise(transcript: rawTranscript,
                                                            apiKey: anthropicApiKey)
                    print("Summary ready")
                    md = buildMarkdown(date: startedAt, duration: duration,
                                       cleanedTranscript: result.cleaned_transcript,
                                       summary: result.summary)
                }

                try md.write(to: mdURL, atomically: true, encoding: .utf8)
                print("Saved: \(mdURL.path)")

                lastMeetingPath = mdURL.path
                status = .ready
                playSound("Glass")  // done cue

                NSWorkspace.shared.selectFile(mdURL.path, inFileViewerRootedAtPath: "")
            }

        } catch {
            isRecording = false
            status = .error(error.localizedDescription)
            print("Recording error: \(error.localizedDescription)")
        }
    }

    // MARK: - Sound

    private func playSound(_ name: String) {
        NSSound(named: name)?.play()
    }

    // MARK: - Clipboard + paste

    private func copyAndPaste(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("Copied to clipboard (\(text.count) chars)")

        guard AXIsProcessTrusted() else {
            print("Accessibility not granted — clipboard only")
            return
        }

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

    var canAutoPaste: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
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
        if let summary { sections += ["", summary] }
        sections += ["", "## Transcript", "", cleanedTranscript]
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
