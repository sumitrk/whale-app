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

@MainActor
final class AIActionCoordinator: ObservableObject {
    @Published private(set) var state: AIActionState = .idle

    private let recorder: AudioRecorder
    private let transcriber: LocalTranscriptionService
    private let runtime: PiRuntime
    private let history: HistoryController
    private let settings: SettingsStore
    private let canStart: () -> Bool

    private var activeRunID: UUID?
    private var historyEntryID: UUID?
    private var snapshot: ContextSnapshot?
    private var modelID: BuiltInModelID = .parakeetEnglishV2
    private var releaseRequested = false
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

        let runID = UUID()
        activeRunID = runID
        releaseRequested = false
        snapshot = nil
        state = .capturingContext

        do {
            guard runtime.hasAPIKey else { throw PiRuntimeError.missingAPIKey }
            guard !settings.openRouterKeyRejected else {
                throw PiRuntimeError.notReady("Replace the rejected OpenRouter API key in Settings > AI Actions")
            }
            if FocusedElementInspector.focusedElementContext()?.snapshot.isSecureTextField == true {
                throw ContextCaptureError.secureField
            }
            modelID = settings.selectedBuiltInModelID
            guard try await transcriber.isModelInstalled(modelID) else {
                throw PiRuntimeError.notReady(modelID.descriptor.installationPrompt)
            }

            let store = try await history.requireStore()
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName
            let entryID = try await store.createEntry(kind: .aiAction, sourceAppName: appName)
            guard isCurrent(runID) else { throw AIActionCoordinatorError.superseded }
            historyEntryID = entryID

            let captured = try await ContextSnapshotCapture.capture()
            guard isCurrent(runID) else { throw AIActionCoordinatorError.superseded }
            snapshot = captured
            try await store.setContext(captured, for: entryID)
            history.changed()

            RecordingIndicatorWindow.shared.show(recorder: recorder)
            try await recorder.startRecording(captureSystemAudio: false)
            guard isCurrent(runID) else { return }
            if releaseRequested, recorder.isRecording {
                startStopAndProcess(runID: runID)
            }
        } catch {
            await fail(runID: runID, error: error)
        }
    }

    func release() {
        guard let runID = activeRunID, state.isActive else { return }
        releaseRequested = true
        if recorder.isRecording {
            startStopAndProcess(runID: runID)
        }
    }

    func cancel(reason: String = "Cancelled") async {
        guard let runID = activeRunID else { return }
        activeRunID = nil
        processingTask?.cancel()
        processingTask = nil
        RecordingIndicatorWindow.shared.hide()
        if recorder.isRecording, let recording = try? await recorder.stopRecording() {
            try? FileManager.default.removeItem(at: recording.wavURL)
        }
        await runtime.abort(runID: runID)
        if let historyEntryID, let store = try? await history.requireStore() {
            try? await store.finalize(historyEntryID, outcome: .cancelled, errorText: reason)
            history.changed()
        }
        clearRunData()
        state = .cancelled
        RecordingIndicatorWindow.shared.showMessage("Cancelled", isError: false, duration: 1)
        settleToIdle(after: .seconds(1))
    }

    private func recordingDidBecomeReady() {
        guard activeRunID != nil, state == .capturingContext else { return }
        state = .listening
        if releaseRequested, let runID = activeRunID {
            startStopAndProcess(runID: runID)
        }
    }

    private func startStopAndProcess(runID: UUID) {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            await self?.stopAndProcess(runID: runID)
        }
    }

    private func stopAndProcess(runID: UUID) async {
        guard isCurrent(runID), let snapshot, let historyEntryID else { return }
        RecordingIndicatorWindow.shared.hide()
        state = .transcribing

        do {
            let recording = try await recorder.stopRecording()
            let wavURL = recording.wavURL
            defer { try? FileManager.default.removeItem(at: wavURL) }
            let instruction = try await transcriber.transcribe(
                modelID: modelID,
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
            let result: String
            do {
                result = try await runtime.perform(runID: runID, request: request)
            } catch is CancellationError where timedOut {
                throw AIActionCoordinatorError.timedOut
            }
            timeoutTask.cancel()

            guard isCurrent(runID) else { throw AIActionCoordinatorError.superseded }
            state = .delivering
            RecordingIndicatorWindow.shared.hide()
            TextInsertionManager.insertOrCopy(result)
            try await store.finalize(
                historyEntryID,
                outcome: .succeeded,
                instructionText: instruction,
                resultText: result
            )
            history.changed()
            activeRunID = nil
            processingTask = nil
            clearRunData()
            state = .succeeded
            settleToIdle(after: .milliseconds(200))
        } catch is CancellationError {
            if isCurrent(runID) { await cancel() }
        } catch {
            await fail(runID: runID, error: error)
        }
    }

    private func fail(runID: UUID, error: Error) async {
        guard isCurrent(runID) else { return }
        activeRunID = nil
        processingTask = nil
        RecordingIndicatorWindow.shared.hide()
        if recorder.isRecording, let recording = try? await recorder.stopRecording() {
            try? FileManager.default.removeItem(at: recording.wavURL)
        }
        await runtime.abort(runID: runID)
        let message = error.localizedDescription
        if isRejectedKeyError(message) {
            settings.openRouterKeyRejected = true
        }
        if let historyEntryID, let store = try? await history.requireStore() {
            try? await store.finalize(historyEntryID, outcome: .failed, errorText: message)
            history.changed()
        }
        clearRunData()
        state = .failed(message)
        RecordingIndicatorWindow.shared.showMessage(message, isError: true, duration: 4)
        settleToIdle(after: .seconds(4))
    }

    private func isCurrent(_ runID: UUID) -> Bool {
        activeRunID == runID
    }

    private func clearRunData() {
        historyEntryID = nil
        snapshot = nil
        releaseRequested = false
    }

    private func settleToIdle(after delay: Duration) {
        let terminalState = state
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.activeRunID == nil, self.state == terminalState else { return }
            self.state = .idle
        }
    }

    private func isRejectedKeyError(_ message: String) -> Bool {
        let value = message.lowercased()
        return value.contains("401") || value.contains("unauthorized") || value.contains("invalid api key")
    }
}
