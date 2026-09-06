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
enum RecordingMode: Sendable, Equatable {
    case markdown   // ⌘⇧T: Transcribe → .md file → Finder
    case paste      // Fn:   Transcribe only → clipboard + auto-paste
}

enum RecordingActivity: Equatable {
    case idle
    case starting(mode: RecordingMode, stopRequested: Bool)
    case recording(mode: RecordingMode, startedAt: Date)
    case processing(mode: RecordingMode)
    case error(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .starting, .recording, .processing:
            return true
        case .idle, .error:
            return false
        }
    }

    var mode: RecordingMode? {
        switch self {
        case .idle, .error:
            return nil
        case .starting(let mode, _), .recording(let mode, _), .processing(let mode):
            return mode
        }
    }

    var startedAt: Date? {
        guard case .recording(_, let startedAt) = self else { return nil }
        return startedAt
    }

    var stopRequested: Bool {
        guard case .starting(_, let stopRequested) = self else { return false }
        return stopRequested
    }

    mutating func requestStop() {
        guard case .starting(let mode, false) = self else { return }
        self = .starting(mode: mode, stopRequested: true)
    }
}

@discardableResult
@MainActor
func playSound(_ name: String) -> TimeInterval {
    guard let sound = NSSound(named: name) else { return 0 }
    let duration = sound.duration
    sound.play()
    return duration
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
    @Published private var activity: RecordingActivity = .idle
    @Published var lastMeetingPath: String? = nil
    /// Set after every transcription — observed by the onboarding test screen.
    @Published var lastTranscript: String = ""

    let recorder = AudioRecorder()
    let hotkey   = HotkeyManager()
    let accessibility: AccessibilityController
    let piRuntime: PiRuntime
    let aiActionCoordinator: AIActionCoordinator

    private let settings = SettingsStore.shared
    private let transcriber = LocalTranscriptionService.shared
    private let transcriptWriter = TranscriptArtifactWriter()
    private let pipelineFactory: () -> TranscriptionPipeline
    private let history = HistoryController.shared
    private var cancellables = Set<AnyCancellable>()
    private var onboardingWindow: NSWindow?
    private var onboardingWindowCloseObserver: NSObjectProtocol?

    private var currentModelID: BuiltInModelID = .parakeetEnglishV2
    private var currentHistoryEntryID: UUID?

    init(
        accessibility: AccessibilityController,
        pipelineFactory: (() -> TranscriptionPipeline)? = nil
    ) {
        self.accessibility = accessibility
        self.pipelineFactory = pipelineFactory ?? {
            // Rebuilt per recording, so a settings change applies to the next one.
            var stages: [PipelineStage] = [
                // VoiceActivityDetectionStage(),
                TranscriptionStage(transcriber: LocalTranscriptionService.shared),
            ]
            if SettingsStore.shared.smartFormattingEnabled {
                stages.append(SmartFormattingStage())
            }
            return TranscriptionPipeline(stages: stages)
        }
        let runtime = PiRuntime()
        self.piRuntime = runtime
        self.aiActionCoordinator = AIActionCoordinator(
            runtime: runtime,
            history: .shared,
            settings: .shared,
            canStart: { true }
        )
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

        Publishers.CombineLatest(settings.$aiActionKeyCode, settings.$aiActionModifiers)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.rebuildHotkeys() }
            .store(in: &cancellables)

        aiActionCoordinator.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.handleAIActionState(state) }
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

    var isRecording: Bool { activity.isRecording }

    private var isBusy: Bool {
        activity.isBusy || status == .starting || aiActionCoordinator.state.isActive
    }

    var statusLabel: String {
        switch status {
        case .starting:      return "Preparing transcription…"
        case .ready:         return "Ready  (⌘⇧T to record | hold Fn to dictate)"
        case .recording:
            if activity.mode == .paste { return "Dictating…  (release Fn to stop)" }
            if activity.mode == .markdown { return "Recording…  (⌘⇧T to stop)" }
            return "Listening for an AI Action…"
        case .transcribing:  return "Transcribing…"
        case .processing(let message): return message
        case .error(let m):  return "Error: \(m)"
        }
    }

    // MARK: - Hotkey setup

    private func rebuildHotkeys() {
        let toggleFlags = NSEvent.ModifierFlags(rawValue: UInt(settings.toggleModifiers))
        let pttFlags = NSEvent.ModifierFlags(rawValue: UInt(settings.pttModifiers))
        let actionFlags = NSEvent.ModifierFlags(rawValue: UInt(settings.aiActionModifiers))
        let toggleAction: @MainActor () -> Void
        let pttPressAction: @MainActor () -> Void

        if accessibility.isTrusted {
            toggleAction = { [weak self] in
                self?.toggleMarkdown()
            }
            pttPressAction = { [weak self] in
                guard let self, !self.isBusy else { return }
                Task { await self.startRecording(mode: .paste) }
            }
        } else {
            toggleAction = { [weak self] in
                self?.toggleMarkdown()
            }
            pttPressAction = { [weak self] in
                guard let self, !self.isBusy else { return }
                self.accessibility.refresh()
                Task { await self.startRecording(mode: .paste) }
            }
        }

        hotkey.rebuild(
            toggleKeyCode: settings.toggleKeyCode,
            toggleModifiers: toggleFlags,
            pttKeyCode: settings.pttKeyCode,
            pttModifiers: pttFlags,
            actionKeyCode: settings.aiActionKeyCode,
            actionModifiers: actionFlags,
            mode: .full,
            onToggle: toggleAction,
            onPTTPress: pttPressAction,
            onPTTRelease: { [weak self] in
                guard let self else { return }
                if case .starting(let mode, _) = self.activity, mode == .paste {
                    self.activity.requestStop()
                    if self.recorder.isRecording {
                        Task { await self.stopRecording() }
                    }
                    return
                }
                guard self.activity.isRecording else { return }
                Task { await self.stopRecording() }
            },
            onActionPress: { [weak self] in
                guard let self else { return }
                if !self.aiActionCoordinator.state.isActive, self.isBusy { return }
                Task { await self.aiActionCoordinator.press() }
            },
            onActionRelease: { [weak self] in
                self?.aiActionCoordinator.release()
            },
            onActionCancel: { [weak self] in
                guard let self, self.aiActionCoordinator.state.isActive else { return }
                Task { await self.aiActionCoordinator.cancel() }
            }
        )
    }

    private func handleRecorderReady() {
        guard case .starting(let mode, let stopRequested) = activity, mode == .paste else { return }
        if stopRequested {
            Task { await self.stopRecording() }
            return
        }
        activity = .recording(mode: .paste, startedAt: Date())
        status = .recording
        playSound("Blow")
    }

    func startClipboardOnlyDictation() {
        guard !isBusy else { return }
        accessibility.refresh()
        Task { await startRecording(mode: .paste) }
    }

    // MARK: - Toggle (⌘⇧T)

    func toggleMarkdown() {
        if case .recording(let mode, _) = activity, mode == .markdown {
            Task { await stopRecording() }
        } else if !isBusy {
            Task { await startRecording(mode: .markdown) }
        }
        // ignore ⌘⇧T while in PTT mode
    }

    // MARK: - Recording core

    fileprivate func startRecording(mode: RecordingMode) async {
        guard !isBusy else { return }

        activity = .starting(mode: mode, stopRequested: false)
        status = .starting

        do {
            let modelID = settings.selectedBuiltInModelID
            guard try await transcriber.isModelInstalled(modelID) else {
                let message = modelID.descriptor.installationPrompt
                DiagnosticLog.log("[Recording] Selected model \(modelID.rawValue) is not installed.")
                activity = .error(message)
                status = .error(message)
                return
            }

            currentModelID = modelID
            if mode == .paste {
                let store = try await history.requireStore()
                currentHistoryEntryID = try await store.createEntry(
                    kind: .dictation,
                    sourceAppName: NSWorkspace.shared.frontmostApplication?.localizedName
                )
                history.changed()
            }
            DiagnosticLog.log("[Recording] Starting \(mode == .paste ? "paste" : "markdown") capture with model \(modelID.rawValue).")
            if mode == .paste {
                RecordingIndicatorWindow.shared.show(recorder: recorder)
            }
            try await recorder.startRecording(captureSystemAudio: mode == .markdown)
            if mode == .markdown {
                activity = .recording(mode: .markdown, startedAt: Date())
                status = .recording
                playSound("Blow")
            } else if activity.stopRequested {
                await stopRecording()
            }
        } catch {
            RecordingIndicatorWindow.shared.hide()
            await finalizeCurrentDictation(outcome: .failed, errorText: error.localizedDescription)
            activity = .error(error.localizedDescription)
            status = .error(error.localizedDescription)
        }
    }

    func stopRecording() async {
        let mode: RecordingMode
        let startedAt: Date
        switch activity {
        case .starting(let activeMode, _):
            mode = activeMode
            startedAt = Date()
        case .recording(let activeMode, let recordingStartedAt):
            mode = activeMode
            startedAt = recordingStartedAt
        case .idle, .processing, .error:
            return
        }

        activity = .processing(mode: mode)
        status = .transcribing
        RecordingIndicatorWindow.shared.hide()

        do {
            let recording = try await recorder.stopRecording()
            let wavURL = recording.wavURL
            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }
            DiagnosticLog.log(
                "[Recording] Stopped capture. WAV=\(wavURL.path) captured=\(recording.capturedSampleCount16k) written=\(recording.writtenSampleCount16k) padded=\(recording.wasPaddedForASR)"
            )
            print(
                "WAV saved: \(wavURL.path) " +
                "[captured=\(recording.capturedSampleCount16k) written=\(recording.writtenSampleCount16k) " +
                "padded=\(recording.wasPaddedForASR) bluetooth=\(recording.isBluetoothInput)]"
            )

            let audioSource: AudioSource = mode == .paste ? .microphone : .system
            let pipeline = pipelineFactory()
            let activeModelID = currentModelID
            let result = try await Task.detached(priority: .userInitiated) {
                try await pipeline.process(
                    wavURL: wavURL,
                    modelID: activeModelID,
                    audioSource: audioSource
                )
            }.value
            let transcript = result.processedTranscript
            DiagnosticLog.log(
                "[Recording] Transcript ready (\(transcript.count) chars, stages: \(result.stagesExecuted.joined(separator: " -> ")))."
            )
            print("Transcript ready (\(transcript.count) chars, stages: \(result.stagesExecuted.joined(separator: " → ")))")
            if !result.warnings.isEmpty {
                print("Pipeline warnings: \(result.warnings.joined(separator: " | "))")
                DiagnosticLog.log("[Recording] Pipeline warnings: \(result.warnings.joined(separator: " | "))")
            }
            lastTranscript = transcript

            defer {
                for artifact in result.artifactsToDelete {
                    try? FileManager.default.removeItem(at: artifact)
                }
            }

            switch mode {

            case .paste:
                activity = .idle
                status = .ready
                RecordingIndicatorWindow.shared.hide()
                guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    DiagnosticLog.log("[Recording] Empty transcript; skipped clipboard insertion.")
                    await finalizeCurrentDictation(outcome: .failed, errorText: "The transcription was empty")
                    return
                }
                TextInsertionManager.insertOrCopy(transcript)
                await finalizeCurrentDictation(
                    outcome: .succeeded,
                    instructionText: transcript,
                    resultText: transcript
                )
                playSound("Bottle")

            case .markdown:
                RecordingIndicatorWindow.shared.hide()
                let duration = Int(Date().timeIntervalSince(startedAt) / 60)
                let artifact = TranscriptArtifactWriter.Document(
                    startedAt: startedAt,
                    durationMinutes: duration,
                    model: currentModelID.descriptor,
                    transcript: transcript
                )
                let mdURL = try transcriptWriter.write(artifact, to: settings.transcriptFolder)
                print("Saved: \(mdURL.path)")

                lastMeetingPath = mdURL.path
                activity = .idle
                status = .ready
                playSound("Bottle")

                NSWorkspace.shared.selectFile(mdURL.path, inFileViewerRootedAtPath: "")

            }

        } catch is CancellationError {
            activity = .idle
            RecordingIndicatorWindow.shared.hide()
            status = .ready
            print("Processing cancelled")
            DiagnosticLog.log("[Recording] Processing cancelled.")
            await finalizeCurrentDictation(outcome: .cancelled, errorText: "Cancelled")
        } catch RecorderError.noAudioCaptured where mode == .paste {
            activity = .idle
            RecordingIndicatorWindow.shared.hide()
            status = .ready
            DiagnosticLog.log("[Recording] No audio was captured in paste mode.")
            await finalizeCurrentDictation(outcome: .failed, errorText: "No audio was captured")
        } catch {
            activity = .error(error.localizedDescription)
            RecordingIndicatorWindow.shared.hide()
            status = .error(error.localizedDescription)
            print("Recording error: \(error.localizedDescription)")
            DiagnosticLog.log("[Recording] Failed: \(error.localizedDescription)")
            await finalizeCurrentDictation(outcome: .failed, errorText: error.localizedDescription)
        }
    }

    private func handleAIActionState(_ actionState: AIActionState) {
        switch actionState {
        case .idle:
            if status != .starting { status = .ready }
        case .capturingContext:
            status = .processing("Capturing context…")
        case .listening:
            status = .recording
        case .transcribing:
            status = .transcribing
        case .processing:
            status = .processing("Running AI Action…")
        case .delivering:
            status = .processing("Delivering…")
        case .succeeded, .cancelled:
            status = .ready
        case .failed(let message):
            status = .error(message)
        }
    }

    private func finalizeCurrentDictation(
        outcome: HistoryOutcome,
        instructionText: String? = nil,
        resultText: String? = nil,
        errorText: String? = nil
    ) async {
        guard let id = currentHistoryEntryID else { return }
        currentHistoryEntryID = nil
        guard let store = try? await history.requireStore() else { return }
        try? await store.finalize(
            id,
            outcome: outcome,
            instructionText: instructionText,
            resultText: resultText,
            errorText: errorText
        )
        history.changed()
    }

    // MARK: - Startup

    private func prepareApp() async {
        RecordingIndicatorWindow.shared.showProcessing()
        defer { RecordingIndicatorWindow.shared.hide() }

        AppRuntimeInfo.migrateSandboxDataIfNeeded()
        recorder.prepareMicrophoneCapture()

        do {
            try await history.prepare()
        } catch {
            status = .error(error.localizedDescription)
            return
        }
        piRuntime.startInBackground()

        if AppRuntimeInfo.current.shouldResetParakeetCacheOnLaunch {
            do {
                try await transcriber.resetModel(.parakeetEnglishV2)
                DiagnosticLog.log("[Parakeet] Reset model cache on launch via \(AppRuntimeInfo.resetParakeetCacheEnvironmentKey).")
            } catch {
                DiagnosticLog.log("[Parakeet] Failed to reset model cache on launch: \(error.localizedDescription)")
            }
        }

        let modelStore = TranscriptionModelStore.shared
        await modelStore.refreshNow()

        let modelID = settings.selectedBuiltInModelID
        if modelStore.isReady(for: modelID) {
            do {
                try await transcriber.prepareModel(modelID)
            } catch {
                DiagnosticLog.log("[Startup] Failed to prepare \(modelID.rawValue): \(error.localizedDescription)")
                status = .error(error.localizedDescription)
                return
            }
        }

        status = .ready
    }
}
