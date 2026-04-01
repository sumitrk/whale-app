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
    case processing(String)
    case error(String)
}

/// Tracks how the current recording was triggered.
fileprivate enum RecordingMode: Sendable {
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
    @Published var lastRawTranscript: String = ""
    @Published var lastProcessingWarnings: [String] = []

    let recorder = AudioRecorder()
    let hotkey   = HotkeyManager()
    let accessibility: AccessibilityController

    private let settings = SettingsStore.shared
    private let transcriber = LocalTranscriptionService.shared
    private let pipelineFactory: @Sendable (TextCleanupSettings) -> TranscriptionPipeline
    private var cancellables = Set<AnyCancellable>()
    private var onboardingWindow: NSWindow?
    private var onboardingWindowCloseObserver: NSObjectProtocol?

    private var recordingStartedAt: Date?
    private var currentMode: RecordingMode = .markdown
    private var currentModelID: BuiltInModelID = .parakeetEnglishV2
    private var isPTTArming = false
    private var stopPTTAfterStart = false
    private var processingTask: Task<PipelineResult, Error>?

    init(
        accessibility: AccessibilityController,
        pipelineFactory: ((TextCleanupSettings) -> TranscriptionPipeline)? = nil
    ) {
        self.accessibility = accessibility
        self.pipelineFactory = pipelineFactory ?? { settings in
            var stages: [PipelineStage] = [
                // VoiceActivityDetectionStage(),
                TranscriptionStage(transcriber: LocalTranscriptionService.shared),
            ]

            if settings.enabled {
                stages.append(LocalLLMCleanupStage())
            }

            return TranscriptionPipeline(stages: stages)
        }
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

        Publishers.CombineLatest3(
            settings.$postProcessingEnabled,
            settings.$cleanupLevel,
            settings.$selectedLocalLLMModelID
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.maybeWarmLocalLLM()
            }
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onboardingWindow = nil
                self.clearOnboardingWindowObserver()
            }
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
        case .processing(let message): return message
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

        processingTask?.cancel()
        processingTask = nil
        lastProcessingWarnings = []
        if status != .starting {
            status = .ready
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
            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }
            print(
                "WAV saved: \(wavURL.path) " +
                "[captured=\(recording.capturedSampleCount16k) written=\(recording.writtenSampleCount16k) " +
                "padded=\(recording.wasPaddedForASR) bluetooth=\(recording.isBluetoothInput)]"
            )

            let cleanupSettings = TextCleanupSettings(store: settings)
            let focusedAppContext = mode == .paste ? FocusedAppContext.capture() : nil
            let outputMode: OutputMode = mode == .paste ? .paste : .markdown
            let audioSource: AudioSource = mode == .paste ? .microphone : .system
            let pipeline = pipelineFactory(cleanupSettings)
            let activeModelID = currentModelID

            lastRawTranscript = ""
            lastProcessingWarnings = []
            if mode == .markdown {
                status = cleanupSettings.enabled ? .processing("Processing…") : .transcribing
            } else {
                status = .ready
            }

            let task = Task.detached(priority: .userInitiated) {
                try await pipeline.process(
                    wavURL: wavURL,
                    modelID: activeModelID,
                    audioSource: audioSource,
                    outputMode: outputMode,
                    postProcessingSettings: cleanupSettings,
                    focusedAppContext: focusedAppContext,
                    progressHandler: { [weak self] message in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            guard mode == .markdown else { return }
                            self.status = .processing(message)
                        }
                    }
                )
            }
            processingTask = task
            let result = try await task.value
            processingTask = nil
            let transcript = result.processedTranscript
            print("Transcript ready (\(transcript.count) chars, stages: \(result.stagesExecuted.joined(separator: " → ")))")
            if result.rawTranscript != result.processedTranscript {
                print("Raw transcript (\(result.rawTranscript.count) chars) differs from processed")
            }
            if !result.warnings.isEmpty {
                print("Pipeline warnings: \(result.warnings.joined(separator: " | "))")
            }
            lastRawTranscript = result.rawTranscript
            lastTranscript = transcript
            lastProcessingWarnings = result.warnings

            defer {
                for artifact in result.artifactsToDelete {
                    try? FileManager.default.removeItem(at: artifact)
                }
            }

            switch mode {

            case .paste:
                status = .ready
                TextInsertionManager.insertOrCopy(transcript)
                playSound("Bottle")

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
                    transcript: transcript,
                    cleanupSummary: cleanupSummary(for: cleanupSettings, result: result)
                )

                try md.write(to: mdURL, atomically: true, encoding: .utf8)
                print("Saved: \(mdURL.path)")

                lastMeetingPath = mdURL.path
                status = .ready
                playSound("Bottle")

                NSWorkspace.shared.selectFile(mdURL.path, inFileViewerRootedAtPath: "")
            }

        } catch is CancellationError {
            processingTask = nil
            status = .ready
            print("Processing cancelled")
        } catch RecorderError.noAudioCaptured where mode == .paste {
            status = .ready
        } catch {
            processingTask = nil
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

    // MARK: - Markdown builder

    private func buildMarkdown(
        date: Date,
        duration: Int,
        model: BuiltInModelDescriptor,
        transcript: String,
        cleanupSummary: String
    ) -> String {
        TranscriptMarkdownBuilder.build(
            date: date,
            duration: duration,
            model: model,
            transcript: transcript,
            formattedDate: formattedDate(date),
            cleanupSummary: cleanupSummary
        )
    }

    private func cleanupSummary(for settings: TextCleanupSettings, result: PipelineResult) -> String {
        guard settings.enabled else {
            return "off (raw transcript)"
        }

        if result.didRunLocalLLM && !result.didFallbackFromLocalLLM {
            let title = settings.localLLMModelID?.descriptor.title
                ?? settings.localLLMModelID?.rawValue
                ?? "Local AI"
            return "\(settings.cleanupLevel.rawValue) (\(title))"
        }

        return "off (raw transcript fallback)"
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
        maybeWarmLocalLLM()
        status = .ready
    }

    private func maybeWarmLocalLLM() {
        guard LocalLLMService.isSupported,
              settings.postProcessingEnabled,
              let modelID = settings.selectedLocalLLMModelID else {
            Task {
                await LocalLLMService.shared.unloadModel()
            }
            return
        }

        Task.detached(priority: .utility) {
            guard (try? await LocalLLMService.shared.isModelInstalled(modelID)) == true else {
                return
            }
            try? await LocalLLMService.shared.prewarmModel(modelID)
        }
    }
}

enum TranscriptMarkdownBuilder {
    static func build(
        date _: Date,
        duration: Int,
        model: BuiltInModelDescriptor,
        transcript: String,
        formattedDate: String,
        cleanupSummary: String
    ) -> String {
        let sections: [String] = [
            "# Meeting — \(formattedDate)",
            "**Duration:** ~\(max(1, duration)) min  |  **Model:** \(model.markdownLabel)",
            "**Cleanup:** \(cleanupSummary)",
            "",
            "## Transcript",
            "",
            transcript,
        ]
        return sections.joined(separator: "\n")
    }
}
