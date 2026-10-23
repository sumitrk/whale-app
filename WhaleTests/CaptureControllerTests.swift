import XCTest
@testable import Whale

@MainActor
final class CaptureControllerTests: XCTestCase {
    private var recorder: FakeRecorder!
    private var history: FakeHistory!
    private var hud: FakeHUD!
    private var models: FakeModels!
    private var aiAction: FakeIntentHandler!
    private var transcriptMode: FakeIntentHandler!
    private var transcript = "hello there"
    private var pipelineError: Error?
    private var delivered: [String] = []
    private var deliveryOutcome: DeliveryOutcome = .inserted
    private var sounds: [FeedbackSound] = []
    private var capture: CaptureController!

    override func setUp() async throws {
        recorder = FakeRecorder()
        history = FakeHistory()
        hud = FakeHUD()
        models = FakeModels()
        aiAction = FakeIntentHandler(completion: { .deliver("Result for \($0.text)", instruction: $0.text) })
        transcriptMode = FakeIntentHandler(completion: { _ in .saved })
        transcript = "hello there"
        pipelineError = nil
        delivered = []
        deliveryOutcome = .inserted
        sounds = []
        capture = CaptureController(
            recorder: recorder,
            models: models,
            history: history,
            hud: hud,
            handlers: [.dictation: DictationHandler(), .transcriptMode: transcriptMode, .aiAction: aiAction],
            pipelineFactory: { [unowned self] in
                TranscriptionPipeline(stages: [
                    FakeTranscriptionStage(text: transcript, error: pipelineError),
                    SuffixStage(suffix: " (formatted)"),
                ])
            },
            deliver: { [unowned self] in
                delivered.append($0)
                return deliveryOutcome
            },
            playSound: { [unowned self] in sounds.append($0) },
            selectedModel: { .parakeetEnglishV2 }
        )
    }

    // MARK: - Lifecycle

    func testDictationInsertsTheProcessedTextAndCompletesItsHistoryEntry() async throws {
        await capture.start(.dictation)
        XCTAssertEqual(capture.phase, .starting(.dictation, stopRequested: false), "waits for the microphone")
        XCTAssertTrue(sounds.isEmpty)

        recorder.becomeReady()
        XCTAssertTrue(capture.phase.isRecording)
        XCTAssertEqual(sounds, [.start])

        capture.release(.dictation)
        await waitUntilIdle()

        XCTAssertEqual(delivered, ["hello there (formatted)"])
        XCTAssertEqual(sounds, [.start, .finish])
        XCTAssertEqual(history.created, [.dictation])
        let entry = try XCTUnwrap(history.finalized.first)
        XCTAssertEqual(entry.outcome, .succeeded)
        XCTAssertEqual(entry.result, "hello there (formatted)")
        XCTAssertEqual(entry.audioSeconds, 2)
        XCTAssertEqual(hud.events, [
            .recording(.dictation, recorder.levelMeter),
            .processing(.dictation),
            .delivered(.inserted),
        ])
        XCTAssertFalse(recorder.capturedSystemAudio)
    }

    func testAReleaseBeforeTheMicrophoneIsUpStillProcesses() async {
        await capture.start(.dictation)
        capture.release(.dictation)
        await waitUntilIdle()

        XCTAssertEqual(delivered, ["hello there (formatted)"])
    }

    func testAIActionInstructionsGetFormattingAndTheDictionaryToo() async throws {
        await capture.start(.aiAction)
        recorder.becomeReady()
        capture.release(.aiAction)
        await waitUntilIdle()

        XCTAssertEqual(aiAction.completed.map(\.text), ["hello there (formatted)"])
        XCTAssertEqual(aiAction.recordedEntries, 1, "context is captured once the History Entry exists")
        XCTAssertEqual(delivered, ["Result for hello there (formatted)"])
        let entry = try XCTUnwrap(history.finalized.first)
        XCTAssertEqual(history.created, [.aiAction])
        XCTAssertEqual(entry.instruction, "hello there (formatted)")
        XCTAssertEqual(entry.result, "Result for hello there (formatted)")
    }

    func testTranscriptModeRecordsSystemAudioWithoutAHistoryEntry() async {
        await capture.start(.transcriptMode)
        XCTAssertTrue(capture.phase.isRecording, "Transcript Mode doesn't wait for the microphone")
        XCTAssertTrue(recorder.capturedSystemAudio)

        capture.release(.transcriptMode)
        await waitUntilIdle()

        XCTAssertEqual(transcriptMode.completed.count, 1)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertTrue(history.created.isEmpty)
        XCTAssertEqual(hud.events, [
            .recording(.transcriptMode, recorder.levelMeter),
            .processing(.transcriptMode),
            .finished,
        ])
    }

    // MARK: - Failures

    func testADictationErrorIsShown() async throws {
        pipelineError = TestError.transcriptionFailed
        await capture.start(.dictation)
        recorder.becomeReady()
        capture.release(.dictation)
        await waitUntilIdle()

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(hud.events.last, .failed("Transcription failed"))
        XCTAssertEqual(history.finalized.first?.outcome, .failed)
    }

    func testAMissingModelFailsBeforeTheMicrophoneOpens() async {
        models.installed = false
        await capture.start(.dictation)

        XCTAssertEqual(capture.phase, .idle)
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertTrue(history.created.isEmpty)
        XCTAssertEqual(hud.events, [.failed(BuiltInModelID.parakeetEnglishV2.descriptor.installationPrompt)])
    }

    func testAHandlerThatRefusesStopsTheCaptureBeforeAnythingShows() async {
        aiAction.readyError = TestError.notReady
        await capture.start(.aiAction)

        XCTAssertEqual(capture.phase, .idle)
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(hud.events, [.failed("Not ready")], "nothing showed before the refusal")
    }

    func testAnEmptyTranscriptLeavesQuietly() async {
        transcript = "   "
        capture = makeCaptureWithoutFormatting()
        await capture.start(.dictation)
        recorder.becomeReady()
        capture.release(.dictation)
        await waitUntilIdle()

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(hud.events.last, .finished)
        XCTAssertEqual(history.finalized.first?.outcome, .failed)
    }

    // MARK: - Cancelling and one at a time

    func testEscapeCancelsADictation() async {
        await capture.start(.dictation)
        recorder.becomeReady()
        await capture.cancelFromEscape()

        XCTAssertEqual(capture.phase, .idle)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(history.finalized.first?.outcome, .cancelled)
        XCTAssertEqual(hud.events.last, .cancelled(replaced: false))
    }

    func testTheDeliveryOutcomeReachesTheHUD() async {
        deliveryOutcome = .copied(.manualPasteOnly)
        await capture.start(.dictation)
        recorder.becomeReady()
        capture.release(.dictation)
        await waitUntilIdle()

        XCTAssertEqual(hud.events.last, .delivered(.copied(.manualPasteOnly)))
    }

    func testEscapeNeverThrowsAwayAMeeting() async {
        await capture.start(.transcriptMode)
        await capture.cancelFromEscape()

        XCTAssertTrue(capture.phase.isRecording)
    }

    func testCancellingWhileTheAIActionRunsStopsItsWork() async {
        aiAction.holdsCompletion = true
        await capture.start(.aiAction)
        recorder.becomeReady()
        capture.release(.aiAction)
        await waitUntil { self.aiAction.isCompleting }

        await capture.cancel()
        aiAction.resumeCompletion()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertTrue(aiAction.wasCancelled)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(history.finalized.map(\.outcome), [.cancelled])
    }

    func testAnotherCaptureIsIgnoredWhileOneIsBusy() async {
        await capture.start(.dictation)
        await capture.start(.transcriptMode)
        await capture.start(.aiAction)

        XCTAssertEqual(capture.phase.intent, .dictation)
        XCTAssertEqual(recorder.starts, 1, "one recorder, one capture")
    }

    func testANewAIActionReplacesTheOneInProgress() async {
        await capture.start(.aiAction)
        recorder.becomeReady()
        await capture.start(.aiAction)

        XCTAssertEqual(history.created, [.aiAction, .aiAction])
        XCTAssertEqual(history.finalized.first?.outcome, .cancelled)
        XCTAssertEqual(history.finalized.first?.error, "Replaced by a newer AI Action")
        XCTAssertTrue(hud.events.contains(.cancelled(replaced: true)))
        XCTAssertFalse(hud.events.contains(.cancelled(replaced: false)))
        XCTAssertEqual(capture.phase, .starting(.aiAction, stopRequested: false))
    }

    // MARK: - Helpers

    private func makeCaptureWithoutFormatting() -> CaptureController {
        CaptureController(
            recorder: recorder,
            models: models,
            history: history,
            hud: hud,
            handlers: [.dictation: DictationHandler()],
            pipelineFactory: { [unowned self] in
                TranscriptionPipeline(stages: [FakeTranscriptionStage(text: transcript, error: nil)])
            },
            deliver: { [unowned self] in
                delivered.append($0)
                return deliveryOutcome
            },
            playSound: { [unowned self] in sounds.append($0) },
            selectedModel: { .parakeetEnglishV2 }
        )
    }

    private func waitUntilIdle() async {
        await waitUntil { self.capture.phase == .idle }
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        let deadline = Date.now.addingTimeInterval(5)
        while !condition(), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out")
    }
}

// MARK: - Fakes

private enum TestError: LocalizedError {
    case transcriptionFailed
    case notReady

    var errorDescription: String? {
        switch self {
        case .transcriptionFailed: "Transcription failed"
        case .notReady: "Not ready"
        }
    }
}

@MainActor
private final class FakeRecorder: CaptureRecorder {
    var isRecording = false
    let levelMeter = MicLevelMeter()
    var onRecordingReady: (() -> Void)?
    var starts = 0
    var capturedSystemAudio = false

    func startRecording(captureSystemAudio: Bool) async throws {
        starts += 1
        capturedSystemAudio = captureSystemAudio
        isRecording = true
    }

    func becomeReady() {
        onRecordingReady?()
    }

    func stopRecording() async throws -> RecordingResult {
        isRecording = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-test-\(UUID()).wav")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return RecordingResult(
            wavURL: url,
            capturedSampleCount16k: 32_000,
            writtenSampleCount16k: 32_000,
            durationSeconds: 2,
            inputDeviceName: "Test",
            isBluetoothInput: false,
            wasPaddedForASR: false
        )
    }
}

private final class FakeModels: CaptureModels, @unchecked Sendable {
    var installed = true
    func isInstalled(_ modelID: BuiltInModelID) async throws -> Bool { installed }
    func warm(_ modelID: BuiltInModelID) {}
}

@MainActor
private final class FakeHUD: CaptureHUD {
    var events: [HUDEvent] = []
    func update(_ event: HUDEvent) { events.append(event) }
}

@MainActor
private final class FakeHistory: CaptureHistory {
    struct Finalized {
        let id: UUID
        let outcome: HistoryOutcome
        let instruction: String?
        let result: String?
        let error: String?
        let audioSeconds: Double?
    }

    var created: [HistoryKind] = []
    var finalized: [Finalized] = []

    func createEntry(kind: HistoryKind, sourceAppName: String?, sourceAppBundleID: String?) async throws -> UUID {
        created.append(kind)
        return UUID()
    }

    func setContext(_ snapshot: ContextSnapshot, for id: UUID) async throws {}
    func setInstruction(_ text: String, for id: UUID) async throws {}

    func finalize(
        _ id: UUID,
        outcome: HistoryOutcome,
        instructionText: String?,
        resultText: String?,
        errorText: String?,
        audioSeconds: Double?
    ) async {
        finalized.append(Finalized(
            id: id, outcome: outcome, instruction: instructionText,
            result: resultText, error: errorText, audioSeconds: audioSeconds
        ))
    }
}

@MainActor
private final class FakeIntentHandler: CaptureIntentHandler {
    let completion: (CaptureTranscript) -> CaptureCompletion
    var readyError: Error?
    var recordedEntries = 0
    var completed: [CaptureTranscript] = []
    var holdsCompletion = false
    var isCompleting = false
    var wasCancelled = false
    private var gate: CheckedContinuation<Void, Never>?

    init(completion: @escaping (CaptureTranscript) -> CaptureCompletion) {
        self.completion = completion
    }

    func checkReady() throws {
        if let readyError { throw readyError }
    }

    func willRecord(entry: CaptureEntry?) async throws {
        if entry != nil { recordedEntries += 1 }
    }

    func complete(_ transcript: CaptureTranscript, entry: CaptureEntry?) async throws -> CaptureCompletion {
        completed.append(transcript)
        if holdsCompletion {
            isCompleting = true
            await withCheckedContinuation { gate = $0 }
        }
        return completion(transcript)
    }

    func resumeCompletion() {
        gate?.resume()
        gate = nil
    }

    func cancel() async {
        wasCancelled = true
    }
}

private struct FakeTranscriptionStage: PipelineStage {
    let name = "Transcription"
    let text: String
    let error: Error?

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        if let error { throw error }
        var updated = context
        updated.rawTranscript = text
        updated.transcript = text
        return updated
    }
}

private struct SuffixStage: PipelineStage {
    let name = "Formatting"
    let suffix: String

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        var updated = context
        updated.transcript += suffix
        return updated
    }
}
