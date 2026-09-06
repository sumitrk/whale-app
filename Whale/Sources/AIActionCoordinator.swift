import AppKit
import Combine
import Foundation

enum AIActionState: Equatable {
    case idle
    case capturingContext
    case listening
    case transcribing
    case processing
    case delivering
    case succeeded
    case cancelled
    case failed(String)

    var isActive: Bool {
        switch self {
        case .capturingContext, .listening, .transcribing, .processing, .delivering:
            return true
        default:
            return false
        }
    }
}

enum AIActionCoordinatorError: LocalizedError {
    case timedOut
    case superseded

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The AI Action timed out after 30 seconds"
        case .superseded: return "The AI Action was replaced by a newer action"
        }
    }
}

final class ActiveRun {
    let id: UUID
    let modelID: BuiltInModelID
    var historyEntryID: UUID?
    var snapshot: ContextSnapshot?
    var releaseRequested = false
    var cancellationReason: String?
    var historyFinalized = false

    init(id: UUID, modelID: BuiltInModelID) {
        self.id = id
        self.modelID = modelID
    }
}

@MainActor
final class AIActionCoordinator: ObservableObject {
    @Published private(set) var state: AIActionState = .idle

    private let recorder: AudioRecorder
    private let transcriber: LocalTranscriptionService
    private let runtime: PiRuntime
    private let history: HistoryController
    private let settings: SettingsStore
    private let canStart: () -> Bool

    private var activeRun: ActiveRun?
    private var processingTask: Task<Void, Never>?

    init(
        recorder: AudioRecorder = AudioRecorder(),
        transcriber: LocalTranscriptionService = .shared,
        runtime: PiRuntime,
        history: HistoryController,
        settings: SettingsStore,
        canStart: @escaping () -> Bool
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.runtime = runtime
        self.history = history
        self.settings = settings
        self.canStart = canStart
        recorder.onRecordingReady = { [weak self] in
            self?.recordingDidBecomeReady()
        }
        recorder.prepareMicrophoneCapture()
    }

    func press() async {
        if state.isActive { await cancel(reason: "Replaced by a newer AI Action") }
        guard canStart() else { return }

        let run = ActiveRun(id: UUID(), modelID: settings.selectedBuiltInModelID)
        activeRun = run
        state = .capturingContext

        do {
            guard runtime.hasAPIKey else { throw PiRuntimeError.missingAPIKey }
            guard !settings.openRouterKeyRejected else {
                throw PiRuntimeError.notReady("Replace the rejected OpenRouter API key in Settings > AI Actions")
            }
            if FocusedElementInspector.focusedElementContext()?.snapshot.isSecureTextField == true {
                throw ContextCaptureError.secureField
            }
            guard try await transcriber.isModelInstalled(run.modelID) else {
                throw PiRuntimeError.notReady(run.modelID.descriptor.installationPrompt)
            }

            let store = try await history.requireStore()
            let frontmost = NSWorkspace.shared.frontmostApplication
            let appName = frontmost?.localizedName
            let entryID = try await store.createEntry(
                kind: .aiAction,
                sourceAppName: appName,
                sourceAppBundleID: SourceApp.bundleID(frontmost?.bundleIdentifier)
            )
            run.historyEntryID = entryID
            guard isCurrent(run.id) else {
                await finalizeHistory(
                    for: run,
                    outcome: .cancelled,
                    errorText: run.cancellationReason ?? "Replaced by a newer AI Action"
                )
                throw AIActionCoordinatorError.superseded
            }

            let captured = try await ContextSnapshotCapture.capture()
            guard isCurrent(run.id) else { throw AIActionCoordinatorError.superseded }
            run.snapshot = captured
            try await store.setContext(captured, for: entryID)
            history.changed()

            RecordingIndicatorWindow.shared.show(recorder: recorder)
            try await recorder.startRecording(captureSystemAudio: false)
            guard isCurrent(run.id) else { return }
            if run.releaseRequested, recorder.isRecording {
                startStopAndProcess(runID: run.id)
            }
        } catch {
            await fail(run: run, error: error)
        }
    }

    func release() {
        guard let run = activeRun, state.isActive else { return }
        run.releaseRequested = true
        if recorder.isRecording {
            startStopAndProcess(runID: run.id)
        }
    }

    func cancel(reason: String = "Cancelled") async {
        guard let run = activeRun else { return }
        run.cancellationReason = reason
        activeRun = nil
        processingTask?.cancel()
        processingTask = nil
        RecordingIndicatorWindow.shared.hide()
        if recorder.isRecording, let recording = try? await recorder.stopRecording() {
            try? FileManager.default.removeItem(at: recording.wavURL)
        }
        await runtime.abort(runID: run.id)
        await finalizeHistory(for: run, outcome: .cancelled, errorText: reason)
        state = .cancelled
        if reason != "Replaced by a newer AI Action" {
            RecordingIndicatorWindow.shared.showMessage("Cancelled", isError: false, duration: 1)
        }
        settleToIdle(after: .seconds(1))
    }

    private func recordingDidBecomeReady() {
        guard let run = activeRun, state == .capturingContext else { return }
        state = .listening
        playSound("Blow")
        if run.releaseRequested {
            startStopAndProcess(runID: run.id)
        }
    }

    private func startStopAndProcess(runID: UUID) {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            await self?.stopAndProcess(runID: runID)
        }
    }

    private func stopAndProcess(runID: UUID) async {
        guard isCurrent(runID), let run = activeRun, let snapshot = run.snapshot, let historyEntryID = run.historyEntryID else { return }
        RecordingIndicatorWindow.shared.hide()
        state = .transcribing

        do {
            let recording = try await recorder.stopRecording()
            let wavURL = recording.wavURL
            defer { try? FileManager.default.removeItem(at: wavURL) }
            let instruction = try await transcriber.transcribe(
                modelID: run.modelID,
                wavURL: wavURL,
                source: .microphone
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isCurrent(runID) else { throw AIActionCoordinatorError.superseded }
            guard !instruction.isEmpty else { throw PiRuntimeError.emptyResult }

            let store = try await history.requireStore()
            try await store.setInstruction(instruction, for: historyEntryID)
            history.changed()
            let request = try AIActionPromptBuilder.build(
                instruction: instruction,
                snapshot: snapshot,
                masterPrompt: settings.aiActionMasterPrompt
            )

            state = .processing
            RecordingIndicatorWindow.shared.showProcessing()
            var timedOut = false
            let timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(30))
                    guard let self, self.isCurrent(runID) else { return }
                    timedOut = true
                    await self.runtime.abort(runID: runID)
                } catch { }
            }
            defer { timeoutTask.cancel() }
            let result: String
            do {
                result = try await runtime.perform(runID: runID, request: request)
            } catch is CancellationError where timedOut {
                throw AIActionCoordinatorError.timedOut
            }

            guard isCurrent(runID) else { throw AIActionCoordinatorError.superseded }
            // A request that went through is the only proof credit exists, and
            // the only way out of the out-of-credit state.
            settings.openRouterOutOfCredit = false
            state = .delivering
            TextInsertionManager.insertOrCopy(result)
            await finalizeHistory(
                for: run,
                outcome: .succeeded,
                instructionText: instruction,
                resultText: result
            )
            playSound("Bottle")
            activeRun = nil
            processingTask = nil
            state = .succeeded
            settleToIdle(after: .milliseconds(200))
        } catch is CancellationError {
            if isCurrent(runID) { await cancel() }
        } catch {
            await fail(run: run, error: error)
        }
    }

    private func fail(run: ActiveRun, error: Error) async {
        guard isCurrent(run.id) else {
            await finalizeHistory(
                for: run,
                outcome: .cancelled,
                errorText: run.cancellationReason ?? "Replaced by a newer AI Action"
            )
            return
        }
        activeRun = nil
        processingTask = nil
        RecordingIndicatorWindow.shared.hide()
        if recorder.isRecording, let recording = try? await recorder.stopRecording() {
            try? FileManager.default.removeItem(at: recording.wavURL)
        }
        await runtime.abort(runID: run.id)
        let message = error.localizedDescription
        switch OpenRouterFailure.classify(message) {
        case .rejectedKey: settings.openRouterKeyRejected = true
        case .outOfCredit: settings.openRouterOutOfCredit = true
        case nil: break
        }
        await finalizeHistory(for: run, outcome: .failed, errorText: message)
        if case RecorderError.noAudioCaptured = error {
            state = .idle
            return
        }
        state = .failed(message)
        RecordingIndicatorWindow.shared.showMessage(message, isError: true, duration: 4)
        settleToIdle(after: .seconds(4))
    }

    private func finalizeHistory(
        for run: ActiveRun,
        outcome: HistoryOutcome,
        instructionText: String? = nil,
        resultText: String? = nil,
        errorText: String? = nil
    ) async {
        guard !run.historyFinalized, let historyEntryID = run.historyEntryID else { return }
        run.historyFinalized = true
        if let store = try? await history.requireStore() {
            try? await store.finalize(
                historyEntryID,
                outcome: outcome,
                instructionText: instructionText,
                resultText: resultText,
                errorText: errorText
            )
            history.changed()
        }
    }

    private func isCurrent(_ runID: UUID) -> Bool {
        activeRun?.id == runID
    }

    private func settleToIdle(after delay: Duration) {
        let terminalState = state
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.activeRun == nil, self.state == terminalState else { return }
            self.state = .idle
        }
    }
}
