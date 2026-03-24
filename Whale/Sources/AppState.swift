import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

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
    /// Set after every transcription — observed by the onboarding test screen.
    @Published var lastTranscript: String = ""
    /// When true, transcription result is shown in lastTranscript but NOT pasted.
    /// Set during onboarding so the test box works without pasting into other apps.
    var suppressPaste = false

    let server   = PythonServer()
    let recorder = AudioRecorder()
    let client   = TranscribeClient()
    let hotkey   = HotkeyManager()

    private let settings = SettingsStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var onboardingWindow: NSWindow?

    private var recordingStartedAt: Date?
    private var currentMode: RecordingMode = .markdown

    init() {
        Task { await startServer() }

        // ⌘⇧T (or user-configured combo) — toggle: full markdown pipeline
        restartToggleHotkey()

        // React to key combo changes in Settings
        Publishers.CombineLatest(settings.$toggleKeyCode, settings.$toggleModifiers)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.restartToggleHotkey() }
            .store(in: &cancellables)

        // PTT (hold to record)
        restartPTTHotkey()

        // React to PTT key changes in Settings
        Publishers.CombineLatest(settings.$pttKeyCode, settings.$pttModifiers)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.restartPTTHotkey() }
            .store(in: &cancellables)

        // Only auto-prompt accessibility for returning users.
        // New users get the prompt via the onboarding permissions step.
        if settings.hasCompletedOnboarding {
            requestAccessibilityIfNeeded()
        }

        if !settings.hasCompletedOnboarding {
            Task { @MainActor [weak self] in self?.showOnboardingWindow() }
        }
    }

    func showOnboardingWindow() {
        if onboardingWindow != nil { onboardingWindow?.makeKeyAndOrderFront(nil); return }
        suppressPaste = true   // don't paste into other apps during onboarding test
        let view = OnboardingView { [weak self] in
            self?.suppressPaste = false
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }
        let hosting = NSHostingView(rootView: view.environmentObject(self))
        hosting.frame = NSRect(x: 0, y: 0, width: 540, height: 460)
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.title = ""
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
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

    // MARK: - Hotkey setup

    private func restartToggleHotkey() {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(settings.toggleModifiers))
        hotkey.start(keyCode: settings.toggleKeyCode, modifiers: flags) { [weak self] in
            self?.toggleMarkdown()
        }
    }

    private func restartPTTHotkey() {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(settings.pttModifiers))
        hotkey.startPushToTalk(
            keyCode: settings.pttKeyCode, modifiers: flags,
            onPress: { [weak self] in
                guard let self, !self.isRecording else { return }
                Task { await self.startRecording(mode: .paste) }
            },
            onRelease: { [weak self] in
                guard let self, self.isRecording else { return }
                Task { await self.stopRecording() }
            }
        )
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
            try await recorder.startRecording(captureSystemAudio: mode == .markdown)
            isRecording = true
            status = .recording
            recordingStartedAt = Date()
            playSound("Blow")  // start cue
            if mode == .paste { RecordingIndicatorWindow.shared.show(recorder: recorder) }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func stopRecording() async {
        let startedAt = recordingStartedAt ?? Date()
        let mode = currentMode
        isRecording = false
        status = .transcribing
        RecordingIndicatorWindow.shared.hide()

        do {
            let wavURL = try await recorder.stopRecording()
            print("WAV saved: \(wavURL.path)")

            let rawTranscript = try await client.transcribe(wavURL: wavURL, model: settings.activeModelId)
            print("Transcript ready (\(rawTranscript.count) chars)")
            lastTranscript = rawTranscript

            switch mode {

            case .paste:
                status = .ready
                playSound("Bottle")
                if !suppressPaste { copyAndPaste(rawTranscript) }
                try? FileManager.default.removeItem(at: wavURL)

            case .markdown:
                let duration = Int(Date().timeIntervalSince(startedAt) / 60)
                let saveURL  = settings.transcriptFolder
                let stamp    = ISO8601DateFormatter().string(from: startedAt)
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "T", with: "_")
                    .replacingOccurrences(of: "Z", with: "")
                let mdURL = saveURL.appendingPathComponent("transcript-\(stamp).md")

                let md: String
                if settings.aiEnabled && !settings.aiApiKey.isEmpty {
                    status = .summarising
                    let result = try await client.summarise(
                        transcript: rawTranscript,
                        apiKey:     settings.aiApiKey,
                        provider:   settings.aiProvider
                    )
                    print("Summary ready")
                    md = buildMarkdown(date: startedAt, duration: duration,
                                       cleanedTranscript: result.cleaned_transcript,
                                       summary: result.summary)
                } else {
                    md = buildMarkdown(date: startedAt, duration: duration,
                                       cleanedTranscript: rawTranscript, summary: nil)
                }

                try md.write(to: mdURL, atomically: true, encoding: .utf8)
                print("Saved: \(mdURL.path)")

                lastMeetingPath = mdURL.path
                status = .ready
                playSound("Bottle")
                try? FileManager.default.removeItem(at: wavURL)

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
        if focusedElementIsTextInput() {
            // A text input is active — snapshot old clipboard, auto-paste, restore after 1s.
            let previous = snapshotClipboard()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let src  = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
                let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
                down?.flags = .maskCommand
                up?.flags   = .maskCommand
                down?.post(tap: .cghidEventTap)
                usleep(10_000)
                up?.post(tap: .cghidEventTap)
            }

            // Restore old clipboard once paste has completed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSPasteboard.general.clearContents()
                if !previous.isEmpty { NSPasteboard.general.writeObjects(previous) }
            }
        } else {
            // No focused text input — copy to clipboard and nudge the user to paste manually.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            RecordingIndicatorWindow.shared.showHint()
        }
    }

    /// Returns true if the currently focused UI element is a writable text input.
    /// Works for native macOS apps AND browsers (Chrome/Safari/Arc expose web
    /// inputs as AXTextField / AXTextArea in their accessibility tree).
    private func focusedElementIsTextInput() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focusedRef else { return false }

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedRef as! AXUIElement, kAXRoleAttribute as CFString, &roleRef
        ) == .success, let role = roleRef as? String else { return false }

        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

    private func snapshotClipboard() -> [NSPasteboardItem] {
        (NSPasteboard.general.pasteboardItems ?? []).compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    // MARK: - Accessibility

    /// Prompt for Accessibility permission whenever it is not currently granted.
    /// Called on every launch so that signature changes (new builds, Sparkle updates,
    /// notarization changes, Universal Binary migration) or manual revocations are
    /// detected and re-prompted automatically.
    /// macOS deduplicates the dialog — if the grant is already valid, nothing is shown.
    private func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
    }

    // MARK: - Markdown builder

    private func buildMarkdown(date: Date, duration: Int,
                               cleanedTranscript: String, summary: String?) -> String {
        var sections: [String] = [
            "# Meeting — \(formattedDate(date))",
            "**Duration:** ~\(max(1, duration)) min  |  **Model:** \(settings.activeModelId)",
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
