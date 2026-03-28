import XCTest
import FluidAudio
@testable import Whale

// MARK: - Mock Stages

struct MockTranscriptionStage: PipelineStage {
    let name: String
    let output: String

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        var ctx = context
        ctx.transcript = output
        return ctx
    }
}

struct AppendingStage: PipelineStage {
    let name: String
    let suffix: String

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        var ctx = context
        ctx.transcript += suffix
        return ctx
    }
}

struct FailingStage: PipelineStage {
    let name: String
    let error: Error

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        throw error
    }
}

private enum TestError: Error, Equatable {
    case stageFailed(String)
}

// MARK: - Tests

final class TranscriptionPipelineTests: XCTestCase {

    private let dummyWAV = URL(fileURLWithPath: "/tmp/test.wav")
    private let dummyModel = BuiltInModelID.parakeetEnglishV2
    private let dummySource = AudioSource.microphone

    // MARK: - Single stage

    func testSingleStageProducesTranscript() async throws {
        let pipeline = TranscriptionPipeline(stages: [
            MockTranscriptionStage(name: "Transcription", output: "Hello world"),
        ])

        let result = try await pipeline.process(
            wavURL: dummyWAV,
            modelID: dummyModel,
            audioSource: dummySource
        )

        XCTAssertEqual(result.processedTranscript, "Hello world")
        XCTAssertEqual(result.stagesExecuted, ["Transcription"])
    }

    // MARK: - Multiple stages run in order

    func testMultipleStagesRunInOrder() async throws {
        let pipeline = TranscriptionPipeline(stages: [
            MockTranscriptionStage(name: "Transcription", output: "raw text"),
            AppendingStage(name: "Cleanup", suffix: " [cleaned]"),
            AppendingStage(name: "Format", suffix: " [formatted]"),
        ])

        let result = try await pipeline.process(
            wavURL: dummyWAV,
            modelID: dummyModel,
            audioSource: dummySource
        )

        XCTAssertEqual(result.processedTranscript, "raw text [cleaned] [formatted]")
        XCTAssertEqual(result.stagesExecuted, ["Transcription", "Cleanup", "Format"])
    }

    // MARK: - Error propagation

    func testErrorInStagePropagates() async {
        let pipeline = TranscriptionPipeline(stages: [
            MockTranscriptionStage(name: "Transcription", output: "some text"),
            FailingStage(name: "BrokenStage", error: TestError.stageFailed("boom")),
            AppendingStage(name: "NeverReached", suffix: " [should not appear]"),
        ])

        do {
            _ = try await pipeline.process(
                wavURL: dummyWAV,
                modelID: dummyModel,
                audioSource: dummySource
            )
            XCTFail("Expected error to be thrown")
        } catch let error as TestError {
            XCTAssertEqual(error, .stageFailed("boom"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testErrorInFirstStageStopsExecution() async {
        let pipeline = TranscriptionPipeline(stages: [
            FailingStage(name: "FailFirst", error: TestError.stageFailed("first")),
            MockTranscriptionStage(name: "NeverReached", output: "should not run"),
        ])

        do {
            _ = try await pipeline.process(
                wavURL: dummyWAV,
                modelID: dummyModel,
                audioSource: dummySource
            )
            XCTFail("Expected error to be thrown")
        } catch let error as TestError {
            XCTAssertEqual(error, .stageFailed("first"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Empty pipeline

    func testEmptyPipelineReturnsEmptyTranscript() async throws {
        let pipeline = TranscriptionPipeline(stages: [])

        let result = try await pipeline.process(
            wavURL: dummyWAV,
            modelID: dummyModel,
            audioSource: dummySource
        )

        XCTAssertEqual(result.processedTranscript, "")
        XCTAssertEqual(result.stagesExecuted, [])
    }

    // MARK: - Context passes through correctly

    func testContextCarriesInputMetadata() async throws {
        let expectedURL = URL(fileURLWithPath: "/tmp/specific-test.wav")
        let expectedModel = BuiltInModelID.whisperLargeV3Turbo
        let expectedSource = AudioSource.system

        let verifyingStage = ContextVerifyingStage(
            expectedWavURL: expectedURL,
            expectedModelID: expectedModel
        )
        let pipeline = TranscriptionPipeline(stages: [verifyingStage])

        let result = try await pipeline.process(
            wavURL: expectedURL,
            modelID: expectedModel,
            audioSource: expectedSource
        )

        XCTAssertEqual(result.processedTranscript, "verified")
    }

    // MARK: - Integration with RecordingBackend

    func testTranscriptionStageWithMockBackend() async throws {
        let backend = RecordingBackend()
        let service = LocalTranscriptionService(backends: [
            .parakeet: backend,
            .whisper: backend,
        ])
        let stage = TranscriptionStage(transcriber: service)
        let pipeline = TranscriptionPipeline(stages: [stage])

        let result = try await pipeline.process(
            wavURL: dummyWAV,
            modelID: .parakeetEnglishV2,
            audioSource: .microphone
        )

        XCTAssertEqual(result.processedTranscript, "ok")
        XCTAssertEqual(result.stagesExecuted, ["Transcription"])

        let calls = await backend.snapshot()
        XCTAssertEqual(calls.transcribed, [.parakeetEnglishV2])
    }
}

// MARK: - Helpers

private struct ContextVerifyingStage: PipelineStage {
    let name = "Verify"
    let expectedWavURL: URL
    let expectedModelID: BuiltInModelID

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        guard context.wavURL == expectedWavURL else {
            throw TestError.stageFailed("wavURL mismatch: \(context.wavURL) != \(expectedWavURL)")
        }
        guard context.modelID == expectedModelID else {
            throw TestError.stageFailed("modelID mismatch: \(context.modelID) != \(expectedModelID)")
        }
        var ctx = context
        ctx.transcript = "verified"
        return ctx
    }
}
