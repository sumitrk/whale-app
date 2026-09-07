import XCTest
@testable import Whale

// MARK: - Prompt

final class S1PromptTests: XCTestCase {

    func testControlLineUsesTrainedValuesVerbatim() {
        let options = TranscriptCleanupOptions(styling: .semiCasual, structure: .lists, context: .email)
        XCTAssertEqual(options.controlLine, "[Styling: semi-casual] [Structure: lists] [Context: email]")
    }

    func testDefaultOptionsMatchTheModelCardDefault() {
        XCTAssertEqual(TranscriptCleanupOptions.default.controlLine,
                       "[Styling: semi-formal] [Structure: prose] [Context: general]")
    }

    /// The single most common way to get blank output out of S1-mini is to leave the
    /// think block out of the assistant turn, so its exact shape is pinned here rather
    /// than left to whoever next edits the prompt.
    func testAssistantTurnOpensWithAnEmptyThinkBlock() {
        XCTAssertEqual(S1Prompt.assistantPrefix, "<|im_start|>assistant\n<think>\n\n</think>\n\n")
    }

    func testPromptMatchesTheDocumentedLiteralString() {
        let prompt = S1Prompt.prompt(for: "so um send the report by uh friday", options: .default)

        XCTAssertEqual(prompt, """
            <|im_start|>system
            You are a text normalizer for speech-to-text transcripts. The input begins with a \
            control line specifying the styling, structure, and context settings; clean the \
            transcript to match those settings and output only the cleaned text.<|im_end|>
            <|im_start|>user
            [Styling: semi-formal] [Structure: prose] [Context: general]
            so um send the report by uh friday<|im_end|>
            <|im_start|>assistant
            <think>

            </think>


            """)
    }

    func testGenerationBudgetTracksInputLength() {
        XCTAssertEqual(S1Prompt.maxTokens(forPromptTokenCount: 100), 162)
        XCTAssertEqual(S1Prompt.maxTokens(forPromptTokenCount: 0), 32)
    }
}

// MARK: - Chunking

final class S1ChunkerTests: XCTestCase {

    func testShortTranscriptIsOnePass() {
        XCTAssertEqual(S1Chunker.chunks("hello there"), ["hello there"])
    }

    func testEmptyTranscriptProducesNoPasses() {
        XCTAssertTrue(S1Chunker.chunks("   \n ").isEmpty)
    }

    func testLongTranscriptIsSplitOnSentenceBoundaries() {
        let sentence = String(repeating: "word ", count: 10).trimmingCharacters(in: .whitespaces) + "."
        let text = Array(repeating: sentence, count: 8).joined(separator: " ")

        let chunks = S1Chunker.chunks(text, budget: 120)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertTrue(chunk.hasSuffix("."), "chunk cut mid-sentence: \(chunk)")
        }
        XCTAssertEqual(
            chunks.joined(separator: " ").replacingOccurrences(of: "  ", with: " "),
            text
        )
    }

    /// Unpunctuated ASR output has no boundary the model would recognize, so an oversized
    /// pass is the right answer — better than a cut the model has never seen.
    func testUnpunctuatedTranscriptIsNotCutMidSentence() {
        let text = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(S1Chunker.chunks(text, budget: 100), [text])
    }
}

// MARK: - Guardrails

final class TranscriptCleanupGuardTests: XCTestCase {

    func testAcceptsAPlausibleRewrite() {
        let raw = "so um i need to like send the the report by uh friday no wait make that thursday"
        let cleaned = "I need to send the report by Thursday."

        XCTAssertEqual(TranscriptCleanupGuard.accept(cleaned: cleaned, raw: raw), cleaned)
    }

    func testAcceptsAnEmptyRewriteOfFillerOnlyInput() {
        XCTAssertEqual(TranscriptCleanupGuard.accept(cleaned: "", raw: "um"), "")
    }

    /// The failure this whole guard exists for: a real dictation coming back as nothing.
    func testRejectsAnEmptyRewriteOfRealSpeech() {
        let raw = "please book the meeting room for tuesday morning"
        XCTAssertNil(TranscriptCleanupGuard.accept(cleaned: "  ", raw: raw))
    }

    func testRejectsARewriteThatDroppedMostOfTheTranscript() {
        let raw = String(repeating: "word ", count: 40)
        XCTAssertNil(TranscriptCleanupGuard.accept(cleaned: "word word word", raw: raw))
    }

    func testRejectsARunawayRewrite() {
        let raw = String(repeating: "word ", count: 20)
        let cleaned = String(repeating: "word ", count: 200)
        XCTAssertNil(TranscriptCleanupGuard.accept(cleaned: cleaned, raw: raw))
    }

    /// A short utterance can legitimately collapse a long way, so the ratio test has to
    /// stay out of its way.
    func testShortUtterancesSkipTheRatioTest() {
        XCTAssertEqual(TranscriptCleanupGuard.accept(cleaned: "Yes.", raw: "uh yeah i mean yes"), "Yes.")
    }

    func testStripsChatMarkersAndEchoedControlLine() {
        let cleaned = "[Styling: semi-formal] [Structure: prose] [Context: general]\nSend the report.<|im_end|>"
        XCTAssertEqual(TranscriptCleanupGuard.accept(cleaned: cleaned, raw: "send the report"), "Send the report.")
    }
}

// MARK: - Stage

private struct StubTranscriptionStage: PipelineStage {
    let name = "Transcription"
    let text: String

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        var updated = context
        updated.rawTranscript = text
        updated.transcript = text
        return updated
    }
}

private struct StubCleanupEngine: TranscriptCleanupEngine {
    let transform: @Sendable (String) async throws -> String

    func clean(_ transcript: String, options _: TranscriptCleanupOptions) async throws -> String {
        try await transform(transcript)
    }
}

final class TranscriptCleanupStageTests: XCTestCase {

    private func context(transcript: String) -> PipelineContext {
        PipelineContext(
            originalWavURL: URL(fileURLWithPath: "/tmp/a.wav"),
            wavURL: URL(fileURLWithPath: "/tmp/a.wav"),
            modelID: .parakeetEnglishV2,
            audioSource: .microphone,
            temporaryArtifacts: [],
            rawTranscript: transcript,
            transcript: transcript,
            warnings: []
        )
    }

    func testReplacesTheTranscriptWithTheRewrite() async throws {
        let stage = TranscriptCleanupStage(engine: StubCleanupEngine { _ in "I need to send the report by Thursday." })
        let result = try await stage.process(
            context(transcript: "so um i need to like send the the report by uh friday no wait make that thursday")
        )

        XCTAssertEqual(result.transcript, "I need to send the report by Thursday.")
    }

    /// The raw transcript is never touched, so History and the artifact writer keep what
    /// was actually said regardless of what the rewriter did with it.
    func testLeavesTheRawTranscriptAlone() async throws {
        let raw = "so um i need to like send the the report by uh friday no wait make that thursday"
        let stage = TranscriptCleanupStage(engine: StubCleanupEngine { _ in "I need to send the report by Thursday." })

        let result = try await stage.process(context(transcript: raw))
        XCTAssertEqual(result.rawTranscript, raw)
    }

    func testEmptyTranscriptSkipsTheModelEntirely() async throws {
        let stage = TranscriptCleanupStage(engine: StubCleanupEngine { _ in
            XCTFail("engine should not be called for an empty transcript")
            return ""
        })

        let result = try await stage.process(context(transcript: "   "))
        XCTAssertEqual(result.transcript, "   ")
    }

    func testAnImplausibleRewriteThrowsSoThePipelineKeepsTheRawTranscript() async {
        let stage = TranscriptCleanupStage(engine: StubCleanupEngine { _ in "" })

        do {
            _ = try await stage.process(context(transcript: "please book the meeting room for tuesday morning"))
            XCTFail("expected the guard to reject an empty rewrite")
        } catch {
            XCTAssertEqual(error as? TranscriptCleanupError, .rejected)
        }
    }

    func testASlowEngineIsAbandonedAtTheBudget() async {
        let stage = TranscriptCleanupStage(
            engine: StubCleanupEngine { _ in
                try await Task.sleep(for: .seconds(30))
                return "never"
            },
            budget: .milliseconds(100)
        )

        do {
            _ = try await stage.process(context(transcript: "the quick brown fox"))
            XCTFail("expected the budget to expire")
        } catch {
            XCTAssertEqual(error as? TranscriptCleanupError, .timedOut)
        }
    }

    /// The stage is recoverable, which is what turns every failure above into "the user
    /// keeps their words" rather than "the dictation errored".
    func testFailureLeavesThePipelineWithTheRawTranscript() async throws {
        let spoken = "please book the meeting room for tuesday morning"
        let pipeline = TranscriptionPipeline(stages: [
            StubTranscriptionStage(text: spoken),
            TranscriptCleanupStage(engine: StubCleanupEngine { _ in "" }),
        ])

        let result = try await pipeline.process(
            wavURL: URL(fileURLWithPath: "/tmp/a.wav"),
            modelID: .parakeetEnglishV2,
            audioSource: .microphone
        )

        XCTAssertEqual(result.processedTranscript, spoken)
        XCTAssertEqual(result.stagesExecuted, ["Transcription"])
        XCTAssertEqual(result.warnings.count, 1)
    }
}

// MARK: - Settings

final class TranscriptCleanupSettingsTests: XCTestCase {

    private func makeDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    @MainActor
    func testCleanupIsOffUntilTheModelIsDownloaded() {
        XCTAssertFalse(SettingsStore(userDefaults: makeDefaults()).transcriptCleanupEnabled)
    }

    @MainActor
    func testSmartFormattingStandsDownWhileCleanupIsOn() {
        let store = SettingsStore(userDefaults: makeDefaults())
        XCTAssertTrue(store.usesSmartFormattingStage)

        store.transcriptCleanupEnabled = true
        XCTAssertFalse(store.usesSmartFormattingStage)
    }

    @MainActor
    func testCleanupOptionsRoundTripAcrossLaunches() {
        let defaults = makeDefaults()

        let first = SettingsStore(userDefaults: defaults)
        first.cleanupStyling = .formal
        first.cleanupStructure = .lists
        first.cleanupContext = .email

        let relaunched = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(relaunched.cleanupOptions,
                       TranscriptCleanupOptions(styling: .formal, structure: .lists, context: .email))
    }
}

// MARK: - Integration

/// The one test that proves the parts fit: real weights, real MLX, real tokenizer, and the
/// worked examples from the model card as the expectation.
///
/// Skipped unless `WHALE_S1_INTEGRATION=1`, because it downloads 633 MB and runs the GPU.
/// Everything above this line runs in milliseconds and needs neither.
final class S1IntegrationTests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WHALE_S1_INTEGRATION"] == "1"
    }

    func testDownloadsAndNormalizesTheModelCardExamples() async throws {
        try XCTSkipUnless(isEnabled, "Set WHALE_S1_INTEGRATION=1 to run against the real model.")

        let installer = S1ModelInstaller()
        if await !installer.isInstalled() {
            try await installer.install { progress in
                if let fraction = progress.fractionCompleted {
                    print("[S1 test] \(progress.phase) \(Int(fraction * 100))%")
                }
            }
        }

        let engine = S1CleanupEngine(installer: installer)

        // Asserted as properties rather than exact strings. The model card's worked
        // examples were measured on the BF16 weights; this is the 8-bit conversion, and it
        // makes small wording choices of its own — it keeps the opening "So" above, for
        // one. Pinning the BF16 output would fail on a difference that costs the user
        // nothing, while saying nothing about whether the prompt format is right.
        //
        // What must hold is what the stage is for: fillers gone, the self-correction
        // resolved to the value the speaker landed on, and spoken forms written out.

        let corrected = try await engine.clean(
            "so um i need to like send the the report by uh friday no wait make that thursday",
            options: .default
        )
        print("[S1 test] corrections -> \(corrected)")
        XCTAssertTrue(corrected.contains("Thursday"), corrected)
        XCTAssertFalse(corrected.contains("Friday"), "kept the abandoned value: \(corrected)")
        XCTAssertFalse(corrected.lowercased().contains(" um "), corrected)
        XCTAssertFalse(corrected.lowercased().contains(" uh "), corrected)
        XCTAssertTrue(corrected.hasSuffix("."), corrected)

        let numbers = try await engine.clean(
            "i think the answer is forty two no sorry forty three",
            options: .default
        )
        print("[S1 test] numbers -> \(numbers)")
        XCTAssertTrue(numbers.contains("43"), numbers)
        XCTAssertFalse(numbers.lowercased().contains("forty"), numbers)

        let email = try await engine.clean("send it to support at superwhisper dot com", options: .default)
        print("[S1 test] email -> \(email)")
        XCTAssertTrue(email.contains("support@superwhisper.com"), email)

        // Filler-only input is documented to come back empty, and the guard has to be the
        // thing that decides what an empty result means — not the model.
        let empty = try await engine.clean("um", options: .default)
        print("[S1 test] filler-only -> \"\(empty)\"")
        XCTAssertTrue(empty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "got: \(empty)")

        // End to end through the stage, guard included: the rewrite has to survive the
        // plausibility check, which is the only path a real dictation takes.
        let stage = TranscriptCleanupStage(engine: engine)
        let raw = "so um i need to like send the the report by uh friday no wait make that thursday"
        let processed = try await stage.process(
            PipelineContext(
                originalWavURL: URL(fileURLWithPath: "/tmp/a.wav"),
                wavURL: URL(fileURLWithPath: "/tmp/a.wav"),
                modelID: .parakeetEnglishV2,
                audioSource: .microphone,
                temporaryArtifacts: [],
                rawTranscript: raw,
                transcript: raw,
                warnings: []
            )
        )
        print("[S1 test] via stage -> \(processed.transcript)")
        XCTAssertTrue(processed.transcript.contains("Thursday"), processed.transcript)
        XCTAssertEqual(processed.rawTranscript, raw)

        await engine.unload()
    }
}
