import AppKit
import Combine
import CoreGraphics
import FluidAudio
import Foundation
import SwiftUI

enum AppStatus: Equatable {
    case starting
    case ready
    case recording
    case transcribing
    case error(String)
}

/// Tracks how the current recording was triggered.
fileprivate enum RecordingMode {
    case markdown   // ⌘⇧T: Transcribe → .md file → Finder
    case paste      // Fn:   Transcribe only → clipboard + auto-paste
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
    @Published var isRecording = false
    @Published var lastMeetingPath: String? = nil
    /// Set after every transcription — observed by the onboarding test screen.
    @Published var lastTranscript: String = ""

    let recorder = AudioRecorder()
    let hotkey   = HotkeyManager()
    let accessibility: AccessibilityController

    private let settings = SettingsStore.shared
    private let transcriber = LocalTranscriptionService.shared
    private var cancellables = Set<AnyCancellable>()
    private var onboardingWindow: NSWindow?
    private var onboardingWindowCloseObserver: NSObjectProtocol?

    private var recordingStartedAt: Date?
    private var currentMode: RecordingMode = .markdown
    private var currentModelID: BuiltInModelID = .parakeetEnglishV2
    private var isPTTArming = false
    private var stopPTTAfterStart = false

    init(accessibility: AccessibilityController) {
        self.accessibility = accessibility
        recorder.onRecordingReady = { [weak self] in
            self?.handleRecorderReady()
        }

        Task { await prepareApp() }

        Publishers.CombineLatest4(
            settings.$toggleKeyCode,
            settings.$toggleModifiers,
            settings.$pttKeyCode,
            settings.$pttModifiers
        )
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.rebuildHotkeys() }
            .store(in: &cancellables)

        accessibility.$isTrusted
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildHotkeys() }
            .store(in: &cancellables)

        accessibility.startMonitoring(promptOnLaunch: settings.hasCompletedOnboarding)
        rebuildHotkeys()

        if !settings.hasCompletedOnboarding {
            Task { @MainActor [weak self] in self?.showOnboardingWindow() }
        }
    }

    func showOnboardingWindow() {
        if onboardingWindow != nil { onboardingWindow?.makeKeyAndOrderFront(nil); return }
        let view = OnboardingView { [weak self] in
            self?.closeOnboardingWindow()
        }
        let hosting = NSHostingView(
            rootView: view
                .environmentObject(self)
                .environmentObject(accessibility)
        )
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
        observeOnboardingWindow(window)
        onboardingWindow = window
    }

    private func observeOnboardingWindow(_ window: NSWindow) {
        clearOnboardingWindowObserver()

        onboardingWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onboardingWindow = nil
            self.clearOnboardingWindowObserver()
        }
    }

    private func closeOnboardingWindow() {
        onboardingWindow?.close()
    }

    private func clearOnboardingWindowObserver() {
        guard let onboardingWindowCloseObserver else { return }
        NotificationCenter.default.removeObserver(onboardingWindowCloseObserver)
        self.onboardingWindowCloseObserver = nil
    }

    var isReady: Bool { status == .ready }

    var statusLabel: String {
        switch status {
        case .starting:      return "Preparing transcription…"
        case .ready:         return "Ready  (⌘⇧T to record | hold Fn to dictate)"
        case .recording:
            return currentMode == .paste
                ? "Dictating…  (release Fn to stop)"
                : "Recording…  (⌘⇧T to stop)"
        case .transcribing:  return "Transcribing…"
        case .error(let m):  return "Error: \(m)"
        }
    }

    // MARK: - Hotkey setup

    private func rebuildHotkeys() {
        let toggleFlags = NSEvent.ModifierFlags(rawValue: UInt(settings.toggleModifiers))
        let pttFlags = NSEvent.ModifierFlags(rawValue: UInt(settings.pttModifiers))
        let toggleAction: @MainActor () -> Void
        let pttPressAction: @MainActor () -> Void

        if accessibility.isTrusted {
            toggleAction = { [weak self] in
                self?.toggleMarkdown()
            }
            pttPressAction = { [weak self] in
                guard let self, !self.isRecording, !self.isPTTArming else { return }
                Task { await self.startRecording(mode: .paste) }
            }
        } else {
            toggleAction = { [weak self] in
                self?.toggleMarkdown()
            }
            pttPressAction = { [weak self] in
                guard let self, !self.isRecording, !self.isPTTArming else { return }
                self.accessibility.refresh()
                Task { await self.startRecording(mode: .paste) }
            }
        }

        hotkey.rebuild(
            toggleKeyCode: settings.toggleKeyCode,
            toggleModifiers: toggleFlags,
            pttKeyCode: settings.pttKeyCode,
            pttModifiers: pttFlags,
            mode: .full,
            onToggle: toggleAction,
            onPTTPress: pttPressAction,
            onPTTRelease: { [weak self] in
                guard let self else { return }
                if self.isPTTArming {
                    self.stopPTTAfterStart = true
                    if self.recorder.isRecording {
                        Task { await self.stopRecording() }
                    }
                    return
                }
                guard self.isRecording else { return }
                Task { await self.stopRecording() }
            }
        )
    }

    private func handleRecorderReady() {
        guard currentMode == .paste, isPTTArming else { return }
        if stopPTTAfterStart {
            stopPTTAfterStart = false
            Task { await self.stopRecording() }
            return
        }
        isPTTArming = false
        isRecording = true
        status = .recording
        recordingStartedAt = Date()
        playSound("Blow")
    }

    func startClipboardOnlyDictation() {
        guard !isRecording, !isPTTArming else { return }
        accessibility.refresh()
        Task { await startRecording(mode: .paste) }
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
        let isDictation = mode == .paste
        if isDictation {
            isPTTArming = true
            stopPTTAfterStart = false
            recordingStartedAt = nil
        }

        do {
            let modelID = settings.selectedBuiltInModelID
            guard try await transcriber.isModelInstalled(modelID) else {
                if isDictation {
                    isPTTArming = false
                    stopPTTAfterStart = false
                }
                status = .error(modelID.descriptor.installationPrompt)
                return
            }

            currentModelID = modelID
            currentMode = mode
            try await recorder.startRecording(captureSystemAudio: mode == .markdown)
            if mode == .markdown {
                isRecording = true
                status = .recording
                recordingStartedAt = Date()
                playSound("Blow")
            } else {
                RecordingIndicatorWindow.shared.show(recorder: recorder)
                if stopPTTAfterStart {
                    stopPTTAfterStart = false
                    await stopRecording()
                    return
                }
            }
        } catch {
            if isDictation {
                isPTTArming = false
                stopPTTAfterStart = false
            }
            status = .error(error.localizedDescription)
        }
    }

    func stopRecording() async {
        let startedAt = recordingStartedAt ?? Date()
        let mode = currentMode
        isPTTArming = false
        stopPTTAfterStart = false
        isRecording = false
        RecordingIndicatorWindow.shared.hide()

        do {
            let recording = try await recorder.stopRecording()
            let wavURL = recording.wavURL
            print(
                "WAV saved: \(wavURL.path) " +
                "[captured=\(recording.capturedSampleCount16k) written=\(recording.writtenSampleCount16k) " +
                "padded=\(recording.wasPaddedForASR) bluetooth=\(recording.isBluetoothInput)]"
            )

            status = .transcribing
            let audioSource: AudioSource = mode == .paste ? .microphone : .system
            let rawTranscript = try await transcriber.transcribe(
                modelID: currentModelID,
                wavURL: wavURL,
                source: audioSource
            )
            print("Transcript ready (\(rawTranscript.count) chars)")
            lastTranscript = rawTranscript

            switch mode {

            case .paste:
                status = .ready
                copyAndPaste(rawTranscript)
                playSound("Bottle")
                try? FileManager.default.removeItem(at: wavURL)

            case .markdown:
                let duration = Int(Date().timeIntervalSince(startedAt) / 60)
                let saveURL  = settings.transcriptFolder
                let stamp    = ISO8601DateFormatter().string(from: startedAt)
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "T", with: "_")
                    .replacingOccurrences(of: "Z", with: "")
                let mdURL = saveURL.appendingPathComponent("transcript-\(stamp).md")

                let md = buildMarkdown(
                    date: startedAt,
                    duration: duration,
                    model: currentModelID.descriptor,
                    transcript: rawTranscript
                )

                try md.write(to: mdURL, atomically: true, encoding: .utf8)
                print("Saved: \(mdURL.path)")

                lastMeetingPath = mdURL.path
                status = .ready
                playSound("Bottle")
                try? FileManager.default.removeItem(at: wavURL)

                NSWorkspace.shared.selectFile(mdURL.path, inFileViewerRootedAtPath: "")
            }

        } catch RecorderError.noAudioCaptured where mode == .paste {
            status = .ready
        } catch {
            isRecording = false
            status = .error(error.localizedDescription)
            print("Recording error: \(error.localizedDescription)")
        }
    }

    // MARK: - Sound

    @discardableResult
    private func playSound(_ name: String) -> TimeInterval {
        guard let sound = NSSound(named: name) else { return 0 }
        let duration = sound.duration
        sound.play()
        return duration
    }

    // MARK: - Clipboard + paste

    private func copyAndPaste(_ text: String) {
        let focusedElement = FocusedElementInspector.snapshot()
        let canAutoPaste = focusedElement?.isWritableTextTarget == true

        logPasteDecision(snapshot: focusedElement, attemptedAutoPaste: canAutoPaste)

        if canAutoPaste {
            // A text input is active — copy transcript and auto-paste it.
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
        } else {
            // No focused text input — copy to clipboard and nudge the user to paste manually.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let reason: RecordingIndicatorWindow.PasteHintReason = AXIsProcessTrusted()
                ? .manualPasteOnly
                : .accessibilityMissing
            RecordingIndicatorWindow.shared.showHint(reason: reason)
        }
    }

    private func logPasteDecision(snapshot: FocusedElementSnapshot?, attemptedAutoPaste: Bool) {
        let appName = snapshot?.appName ?? "unknown"
        let bundle = snapshot?.bundleIdentifier ?? "unknown"
        let role = snapshot?.role ?? "nil"
        let subrole = snapshot?.subrole ?? "nil"
        let editable = snapshot?.isEditable ?? false
        let selectedTextRange = snapshot?.supportsSelectedTextRange ?? false
        let decision = attemptedAutoPaste ? "auto-paste" : "clipboard-only"

        print(
            "AutoPaste decision=\(decision) app=\(appName) bundle=\(bundle) role=\(role) subrole=\(subrole) editable=\(editable) selectedTextRange=\(selectedTextRange)"
        )
    }

    // MARK: - Markdown builder

    private func buildMarkdown(
        date: Date,
        duration: Int,
        model: BuiltInModelDescriptor,
        transcript: String
    ) -> String {
        TranscriptMarkdownBuilder.build(
            date: date,
            duration: duration,
            model: model,
            transcript: transcript,
            formattedDate: formattedDate(date)
        )
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Startup

    private func prepareApp() async {
        await TranscriptionModelStore.shared.refreshNow()
        status = .ready
    }
}

enum TranscriptMarkdownBuilder {
    static func build(
        date _: Date,
        duration: Int,
        model: BuiltInModelDescriptor,
        transcript: String,
        formattedDate: String
    ) -> String {
        let sections: [String] = [
            "# Meeting — \(formattedDate)",
            "**Duration:** ~\(max(1, duration)) min  |  **Model:** \(model.markdownLabel)",
            "",
            "> AI cleanup and summarisation are temporarily disabled in the native build. This file contains the raw transcript.",
            "",
            "## Transcript",
            "",
            transcript,
        ]
        return sections.joined(separator: "\n")
    }
}
