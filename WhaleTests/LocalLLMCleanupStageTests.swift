import XCTest
@testable import Whale

final class LocalLLMCleanupStageTests: XCTestCase {
    func testStageUsesCleanerForLightCleanup() async throws {
        let stage = LocalLLMCleanupStage(clean: { transcript, _, _ in
            XCTAssertEqual(transcript, "raw text")
            return "lightly cleaned"
        })

        let result = try await stage.process(.context(cleanupLevel: .light))
        XCTAssertEqual(result.transcript, "lightly cleaned")
        XCTAssertTrue(result.didRunLocalLLM)
    }

    func testStageUsesCleanerWhenEnabled() async throws {
        let stage = LocalLLMCleanupStage(clean: { transcript, _, _ in
            XCTAssertEqual(transcript, "raw text")
            return "cleaned text"
        })

        let result = try await stage.process(.context(cleanupLevel: .medium))
        XCTAssertEqual(result.transcript, "cleaned text")
        XCTAssertTrue(result.didRunLocalLLM)
    }

    func testRecoverableFailureFallsBackViaPipeline() async throws {
        let stage = LocalLLMCleanupStage(clean: { _, _, _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        })
        let pipeline = TranscriptionPipeline(stages: [SeedTranscriptStage(), stage])

        let result = try await pipeline.process(
            wavURL: URL(fileURLWithPath: "/tmp/test.wav"),
            modelID: .parakeetEnglishV2,
            audioSource: .microphone,
            outputMode: .paste,
            postProcessingSettings: .stub(cleanupLevel: .medium),
            focusedAppContext: nil
        )

        XCTAssertEqual(result.processedTranscript, "raw text")
        XCTAssertTrue(result.didFallbackFromLocalLLM)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testPasteModeChunksLongTranscriptInsteadOfSkippingLLM() async throws {
        let longTranscript = """
        this is the first sentence that should be cleaned by qwen before paste. \
        here is the second sentence which makes the transcript long enough to require chunking. \
        finally this third sentence keeps the dictation long but should still go through the llm cleanup path.
        """
        let observedChunks = ObservedChunks()
        let stage = LocalLLMCleanupStage(clean: { chunk, _, _ in
            await observedChunks.append(chunk)
            return chunk.uppercased()
        })
        let pipeline = TranscriptionPipeline(stages: [SeedTranscriptStage(output: longTranscript), stage])

        let result = try await pipeline.process(
            wavURL: URL(fileURLWithPath: "/tmp/test.wav"),
            modelID: .parakeetEnglishV2,
            audioSource: .microphone,
            outputMode: .paste,
            postProcessingSettings: .stub(cleanupLevel: .medium),
            focusedAppContext: nil
        )

        let chunks = await observedChunks.value
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(result.didRunLocalLLM)
        XCTAssertFalse(result.didFallbackFromLocalLLM)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.processedTranscript, chunks.map { $0.uppercased() }.joined(separator: " "))
    }

    func testMarkdownModeStillRunsForLongTranscript() async throws {
        let longTranscript = Array(repeating: "word", count: 40).joined(separator: " ")
        let stage = LocalLLMCleanupStage(clean: { transcript, _, _ in
            XCTAssertEqual(transcript, longTranscript)
            return "cleaned"
        })

        let result = try await stage.process(.context(cleanupLevel: .medium, transcript: longTranscript, outputMode: .markdown))

        XCTAssertEqual(result.transcript, "cleaned")
        XCTAssertTrue(result.didRunLocalLLM)
    }
}

private struct SeedTranscriptStage: PipelineStage {
    let name = "Seed Transcript"
    var output = "raw text"

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        var updated = context
        updated.rawTranscript = output
        updated.transcript = output
        return updated
    }
}

private actor ObservedChunks {
    private var storage: [String] = []

    func append(_ value: String) {
        storage.append(value)
    }

    var value: [String] { storage }
}

private extension PipelineContext {
    static func context(
        cleanupLevel: CleanupLevel,
        transcript: String = "raw text",
        outputMode: OutputMode = .paste
    ) -> PipelineContext {
        PipelineContext(
            originalWavURL: URL(fileURLWithPath: "/tmp/test.wav"),
            wavURL: URL(fileURLWithPath: "/tmp/test.wav"),
            modelID: .parakeetEnglishV2,
            audioSource: .microphone,
            outputMode: outputMode,
            postProcessingSettings: TextCleanupSettings(
                enabled: true,
                cleanupLevel: cleanupLevel,
                localLLMModelID: .qwen3_0_6b_4bit,
                cleanupPromptOverride: ""
            ),
            focusedAppContext: nil,
            progressHandler: { _ in },
            temporaryArtifacts: [],
            rawTranscript: transcript,
            transcript: transcript,
            warnings: [],
            didRunLocalLLM: false,
            didFallbackFromLocalLLM: false
        )
    }
}

private extension TextCleanupSettings {
    static func stub(cleanupLevel: CleanupLevel) -> TextCleanupSettings {
        TextCleanupSettings(
            enabled: true,
            cleanupLevel: cleanupLevel,
            localLLMModelID: .qwen3_0_6b_4bit,
            cleanupPromptOverride: ""
        )
    }
}
