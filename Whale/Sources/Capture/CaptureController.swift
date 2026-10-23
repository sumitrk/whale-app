import AppKit
import Combine
import Foundation

/// Runs every capture, whatever it's for: Dictation, Transcript Mode and AI Action share one
/// lifecycle (model check, History Entry, one recorder, early release, the transcription
/// pipeline, errors, sounds and cancelling). The intent only decides what happens to the text,
/// through its `CaptureIntentHandler`.
///
/// One capture at a time. A new AI Action replaces one in progress; anything else that arrives
/// while busy is ignored.
@MainActor
final class CaptureController: ObservableObject {
    @Published private(set) var phase: CapturePhase = .idle

    /// The text of the last capture, as transcribed.
    private(set) var lastTranscript = ""

    private let recorder: CaptureRecorder
    private let models: CaptureModels
    private let history: CaptureHistory
    private let hud: CaptureHUD
    private let handlers: [CaptureIntent: CaptureIntentHandler]
    private let pipelineFactory: () -> TranscriptionPipeline
    private let deliver: @MainActor (String) -> PasteHintReason?
    private let playSound: (FeedbackSound) -> Void
    private let selectedModel: () -> BuiltInModelID
    private let canStart: () -> Bool

    private var run: Run?
    private var processingTask: Task<Void, Never>?

    private final class Run {
        let id = UUID()
        let intent: CaptureIntent
        let handler: CaptureIntentHandler
        let modelID: BuiltInModelID
        var entry: CaptureEntry?
        var cancellationReason = "Cancelled"
        var finalized = false

        init(intent: CaptureIntent, handler: CaptureIntentHandler, modelID: BuiltInModelID) {
            self.intent = intent
            self.handler = handler
            self.modelID = modelID
        }
    }

    private static let replacedReason = "Replaced by a newer AI Action"

    init(
        recorder: CaptureRecorder,
        models: CaptureModels,
        history: CaptureHistory,
        hud: CaptureHUD,
        handlers: [CaptureIntent: CaptureIntentHandler],
        pipelineFactory: @escaping () -> TranscriptionPipeline,
        deliver: @escaping @MainActor (String) -> PasteHintReason?,
        playSound: @escaping (FeedbackSound) -> Void = { $0.play() },
        selectedModel: @escaping () -> BuiltInModelID,
        canStart: @escaping () -> Bool = { true }
    ) {
        self.recorder = recorder
        self.models = models
        self.history = history
        self.hud = hud
        self.handlers = handlers
        self.pipelineFactory = pipelineFactory
        self.deliver = deliver
        self.playSound = playSound
        self.selectedModel = selectedModel
        self.canStart = canStart
        recorder.onRecordingReady = { [weak self] in
            self?.microphoneDidBecomeReady()
        }
    }

    var isBusy: Bool { phase.isBusy }

    // MARK: - Start, release, cancel

    func start(_ intent: CaptureIntent) async {
        if let current = phase.intent {
            guard current == .aiAction, intent == .aiAction else { return }
            await cancel(reason: Self.replacedReason)
        }
        guard canStart(), let handler = handlers[intent] else { return }

        let run = Run(intent: intent, handler: handler, modelID: selectedModel())
        self.run = run
        phase = .starting(intent, stopRequested: false)

        do {
            try handler.checkReady()
            guard try await models.isInstalled(run.modelID) else {
                DiagnosticLog.log("[Capture] Selected model \(run.modelID.rawValue) is not installed.")
                throw AIActionError.notReady(run.modelID.descriptor.installationPrompt)
            }
            try ensureCurrent(run)
            // Usually loaded at launch. When it isn't (just switched, or still compiling for the
            // Neural Engine after an update), loading now overlaps with the user talking.
            models.warm(run.modelID)
            // Before the History write and the microphone, so the HUD answers the key at once.
            hud.update(.recording(intent, recorder.levelMeter))

            if let kind = intent.historyKind {
                let frontmost = NSWorkspace.shared.frontmostApplication
                let id = try await history.createEntry(
                    kind: kind,
                    sourceAppName: frontmost?.localizedName,
                    sourceAppBundleID: SourceApp.bundleID(frontmost?.bundleIdentifier)
                )
                run.entry = CaptureEntry(id: id, history: history)
                try ensureCurrent(run)
            }
            try await handler.willRecord(entry: run.entry)
            try ensureCurrent(run)

            DiagnosticLog.log("[Capture] Starting \(intent.diagnosticName) with model \(run.modelID.rawValue).")
            try await recorder.startRecording(captureSystemAudio: intent.capturesSystemAudio)
            try ensureCurrent(run)

            // A release that came while the microphone was starting stops it now; otherwise
            // Transcript Mode is recording, and the others wait for the microphone's first audio.
            guard case .starting(_, let stopRequested) = phase else { return }
            if stopRequested {
                stopAndProcess(run)
            } else if !intent.waitsForMicrophone {
                beginRecording(run)
            }
        } catch {
            await fail(run, error: error)
        }
    }

    /// Stops recording and processes what was said: the key released in hold mode, pressed
    /// again in toggle mode. A release while the microphone is still starting is remembered.
    func release(_ intent: CaptureIntent) {
        guard let run, run.intent == intent else { return }
        switch phase {
        case .starting:
            phase = .starting(intent, stopRequested: true)
            if recorder.isRecording { stopAndProcess(run) }
        case .recording:
            stopAndProcess(run)
        case .idle, .processing:
            break
        }
    }

    /// Escape: abandons a Dictation or AI Action in any phase. Transcript Mode ignores it.
    func cancelFromEscape() async {
        guard phase.intent?.cancelsOnEscape == true else { return }
        await cancel(reason: "Cancelled")
    }

    func cancel(reason: String = "Cancelled") async {
        guard let run else { return }
        run.cancellationReason = reason
        self.run = nil
        processingTask?.cancel()
        processingTask = nil
        phase = .idle
        hud.update(.cancelled(replaced: reason == Self.replacedReason))
        await stopRecorderDiscardingAudio()
        await run.handler.cancel()
        await finalize(run, outcome: .cancelled, errorText: reason)
        DiagnosticLog.log("[Capture] Cancelled \(run.intent.diagnosticName): \(reason).")
    }

    // MARK: - Lifecycle

    private func microphoneDidBecomeReady() {
        guard let run, run.intent.waitsForMicrophone, case .starting(_, let stopRequested) = phase else { return }
        beginRecording(run)
        if stopRequested {
            stopAndProcess(run)
        }
    }

    private func beginRecording(_ run: Run) {
        phase = .recording(run.intent, startedAt: .now)
        playSound(.start)
    }

    private func stopAndProcess(_ run: Run) {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            await self?.process(run)
        }
    }

    private func process(_ run: Run) async {
        let startedAt = phase.recordingStartedAt ?? .now
        phase = .processing(run.intent)
        hud.update(.processing(run.intent))

        do {
            let recording = try await recorder.stopRecording()
            let wavURL = recording.wavURL
            defer { try? FileManager.default.removeItem(at: wavURL) }
            DiagnosticLog.log(
                "[Capture] Stopped. captured=\(recording.capturedSampleCount16k) written=\(recording.writtenSampleCount16k) " +
                "padded=\(recording.wasPaddedForASR) bluetooth=\(recording.isBluetoothInput)"
            )

            let pipeline = pipelineFactory()
            let modelID = run.modelID
            let source = run.intent.audioSource
            let result = try await Task.detached(priority: .userInitiated) {
                try await pipeline.process(wavURL: wavURL, modelID: modelID, audioSource: source)
            }.value
            defer {
                for artifact in result.artifactsToDelete {
                    try? FileManager.default.removeItem(at: artifact)
                }
            }
            if !result.warnings.isEmpty {
                DiagnosticLog.log("[Capture] Pipeline warnings: \(result.warnings.joined(separator: " | "))")
            }
            try ensureCurrent(run)

            let text = result.processedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            lastTranscript = text
            DiagnosticLog.log("[Capture] Transcript ready (\(text.count) chars, stages: \(result.stagesExecuted.joined(separator: " -> "))).")
            guard !text.isEmpty else {
                // Nothing was said; leave quietly.
                end(run)
                hud.update(.finished)
                await finalize(run, outcome: .failed, errorText: "The transcription was empty")
                return
            }

            let audioSeconds = Double(recording.capturedSampleCount16k) / 16_000
            let transcript = CaptureTranscript(text: text, startedAt: startedAt, modelID: modelID, audioSeconds: audioSeconds)
            let completion = try await run.handler.complete(transcript, entry: run.entry)
            try ensureCurrent(run)

            end(run)
            switch completion {
            case .deliver(let output, let instruction):
                hud.update(.delivered(pasteHint: deliver(output)))
                await finalize(run, outcome: .succeeded, instructionText: instruction, resultText: output, audioSeconds: audioSeconds)
            case .saved:
                hud.update(.finished)
            }
            playSound(.finish)
        } catch {
            await fail(run, error: error)
        }
    }

    /// Any failure, in any phase. Superseded or cancelled runs are already accounted for.
    private func fail(_ run: Run, error: Error) async {
        guard self.run === run else {
            await finalize(run, outcome: .cancelled, errorText: run.cancellationReason)
            return
        }
        if error is CancellationError {
            await cancel()
            return
        }
        end(run)
        let message = error.localizedDescription
        // A tap too short to capture anything isn't worth a message.
        if case RecorderError.noAudioCaptured = error {
            hud.update(.finished)
        } else {
            hud.update(.failed(message))
        }
        await stopRecorderDiscardingAudio()
        await run.handler.cancel()
        DiagnosticLog.log("[Capture] \(run.intent.diagnosticName) failed: \(message)")
        await finalize(run, outcome: .failed, errorText: message)
    }

    private func end(_ run: Run) {
        guard self.run === run else { return }
        self.run = nil
        processingTask = nil
        phase = .idle
    }

    private func ensureCurrent(_ run: Run) throws {
        guard self.run === run else { throw CancellationError() }
    }

    private func stopRecorderDiscardingAudio() async {
        guard recorder.isRecording, let recording = try? await recorder.stopRecording() else { return }
        try? FileManager.default.removeItem(at: recording.wavURL)
    }

    private func finalize(
        _ run: Run,
        outcome: HistoryOutcome,
        instructionText: String? = nil,
        resultText: String? = nil,
        errorText: String? = nil,
        audioSeconds: Double? = nil
    ) async {
        guard !run.finalized, let entry = run.entry else { return }
        run.finalized = true
        await history.finalize(
            entry.id,
            outcome: outcome,
            instructionText: instructionText,
            resultText: resultText,
            errorText: errorText,
            audioSeconds: audioSeconds
        )
    }
}

private extension CapturePhase {
    var recordingStartedAt: Date? {
        if case .recording(_, let startedAt) = self { return startedAt }
        return nil
    }
}
