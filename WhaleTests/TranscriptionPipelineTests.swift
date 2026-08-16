import FluidAudio
import XCTest
@testable import Whale

struct MockTranscriptionStage: PipelineStage {
    let name: String
    let output: String

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        var context = context
        context.rawTranscript = output
        context.transcript = output
        return context
    }
}

struct AppendingStage: PipelineStage {
    let name: String
    let suffix: String

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        var context = context
        context.transcript += suffix
        return context
    }
}

private struct FailingStage: PipelineStage {
    let name: String
    let isRecoverable: Bool
    func process(_ context: PipelineContext) async throws -> PipelineContext { throw TestError.failed }
}

private enum TestError: Error { case failed }

final class TranscriptionPipelineTests: XCTestCase {
    private let wav = URL(fileURLWithPath: "/tmp/test.wav")

    func testStagesRunInOrderAndPreserveRawTranscript() async throws {
        let pipeline = TranscriptionPipeline(stages: [
            MockTranscriptionStage(name: "Transcription", output: "raw"),
            AppendingStage(name: "Format", suffix: " formatted"),
        ])
        let result = try await pipeline.process(
            wavURL: wav,
            modelID: .parakeetEnglishV2,
            audioSource: .microphone
        )
        XCTAssertEqual(result.rawTranscript, "raw")
        XCTAssertEqual(result.processedTranscript, "raw formatted")
        XCTAssertEqual(result.stagesExecuted, ["Transcription", "Format"])
    }

    func testNonrecoverableErrorStopsPipeline() async {
        let pipeline = TranscriptionPipeline(stages: [
            FailingStage(name: "Broken", isRecoverable: false),
            MockTranscriptionStage(name: "Never", output: "no"),
        ])
        do {
            _ = try await pipeline.process(wavURL: wav, modelID: .parakeetEnglishV2, audioSource: .microphone)
            XCTFail("Expected the stage error")
        } catch is TestError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRecoverableErrorRecordsWarningAndContinues() async throws {
        let pipeline = TranscriptionPipeline(stages: [
            MockTranscriptionStage(name: "Transcription", output: "raw"),
            FailingStage(name: "Optional", isRecoverable: true),
            AppendingStage(name: "Format", suffix: " kept"),
        ])
        let result = try await pipeline.process(wavURL: wav, modelID: .parakeetEnglishV2, audioSource: .microphone)
        XCTAssertEqual(result.processedTranscript, "raw kept")
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testTranscriptionStageUsesSelectedLocalModel() async throws {
        let backend = RecordingBackend()
        let service = LocalTranscriptionService(backends: [.parakeet: backend, .whisper: backend])
        let pipeline = TranscriptionPipeline(stages: [TranscriptionStage(transcriber: service)])
        let result = try await pipeline.process(wavURL: wav, modelID: .parakeetEnglishV2, audioSource: .microphone)
        XCTAssertEqual(result.processedTranscript, "ok")
        let backendSnapshot = await backend.snapshot()
        XCTAssertEqual(backendSnapshot.transcribed, [.parakeetEnglishV2])
    }
}
