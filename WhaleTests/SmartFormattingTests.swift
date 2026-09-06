import TextProcessing
import XCTest
@testable import Whale

final class SmartFormattingStageTests: XCTestCase {
    private let wav = URL(fileURLWithPath: "/tmp/test.wav")

    private func context(transcript: String) -> PipelineContext {
        PipelineContext(
            originalWavURL: wav,
            wavURL: wav,
            modelID: .parakeetEnglishV2,
            audioSource: .microphone,
            temporaryArtifacts: [],
            rawTranscript: transcript,
            transcript: transcript,
            warnings: []
        )
    }

    func testFormatsTranscriptAndLeavesRawUntouched() async throws {
        let stage = SmartFormattingStage(format: { $0.replacingOccurrences(of: "twenty one", with: "21") })
        let result = try await stage.process(context(transcript: "I have twenty one apples"))

        XCTAssertEqual(result.transcript, "I have 21 apples")
        XCTAssertEqual(result.rawTranscript, "I have twenty one apples")
    }

    func testEmptyTranscriptSkipsTheFormatter() async throws {
        let formatterRan = Expectation()
        let stage = SmartFormattingStage(format: { text in
            formatterRan.fulfill()
            return text
        })

        let result = try await stage.process(context(transcript: "   \n "))

        XCTAssertEqual(result.transcript, "   \n ")
        XCTAssertFalse(formatterRan.didRun)
    }

    func testEmptyResultKeepsTheOriginalTranscript() async throws {
        let stage = SmartFormattingStage(format: { _ in "" })
        let result = try await stage.process(context(transcript: "hello world"))

        XCTAssertEqual(result.transcript, "hello world")
    }

    func testStageIsRecoverableSoAFailureCannotLoseATranscript() {
        XCTAssertTrue(SmartFormattingStage().isRecoverable)
    }

    /// The stage is only appended when Smart Formatting is on, so a pipeline
    /// without it must hand back exactly what transcription produced.
    func testPipelineWithoutTheStageLeavesTheTranscriptAlone() async throws {
        let pipeline = TranscriptionPipeline(stages: [
            MockTranscriptionStage(name: "Transcription", output: "I have twenty one apples")
        ])
        let result = try await pipeline.process(
            wavURL: wav,
            modelID: .parakeetEnglishV2,
            audioSource: .microphone
        )

        XCTAssertEqual(result.processedTranscript, "I have twenty one apples")
        XCTAssertEqual(result.stagesExecuted, ["Transcription"])
    }

    private final class Expectation: @unchecked Sendable {
        private(set) var didRun = false
        func fulfill() { didRun = true }
    }
}

/// Exercises the linked `text-processing-rs` engine itself, so a bad or missing
/// binary artifact fails here rather than silently passing transcripts through.
final class SpokenFormNormalizerTests: XCTestCase {
    func testEngineIsLinked() {
        XCTAssertFalse(SpokenFormNormalizer.engineVersion.isEmpty)
        XCTAssertNotEqual(SpokenFormNormalizer.engineVersion, "unknown")
    }

    func testRewritesNumbersMoneyAndDates() {
        XCTAssertEqual(SpokenFormNormalizer.writtenForm("I have twenty one apples"), "I have 21 apples")
        XCTAssertEqual(
            SpokenFormNormalizer.writtenForm("send twenty one dollars and fifty cents to bob"),
            "send $21.50 to bob"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.writtenForm("the meeting is january fifth twenty twenty five"),
            "the meeting is january 5 2025"
        )
    }

    func testLeavesTextWithNothingToRewriteAlone() {
        let plain = "can you send me the doc"
        XCTAssertEqual(SpokenFormNormalizer.writtenForm(plain), plain)
    }

    func testKeepBareSecondProtectsTheWordButNotCompoundOrdinals() {
        XCTAssertEqual(
            SpokenFormNormalizer.writtenForm("wait a second please", keepBareSecond: true),
            "wait a second please"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.writtenForm("wait a second please", keepBareSecond: false),
            "wait a 2nd please"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.writtenForm("the twenty second item", keepBareSecond: true),
            "the 22nd item"
        )
    }

    func testEmptyInputStaysEmpty() {
        XCTAssertEqual(SpokenFormNormalizer.writtenForm(""), "")
    }

    /// Parakeet writes "twenty-one" whenever it falls back to spoken form, which
    /// is the case this whole stage exists to repair.
    func testRewritesHyphenatedCompoundNumbers() {
        XCTAssertEqual(
            SpokenFormNormalizer.writtenForm("I have twenty-one apples."),
            "I have 21 apples."
        )
        XCTAssertEqual(
            SpokenFormNormalizer.writtenForm("It cost thirty-five dollars."),
            "It cost $35."
        )
    }

    func testLeavesHyphenatedWordsThatAreNotNumbersAlone() {
        let plain = "we shipped a state-of-the-art build"
        XCTAssertEqual(SpokenFormNormalizer.writtenForm(plain), plain)
    }

    /// A compound number inside a longer hyphen chain is left alone: opening it
    /// hands the engine a dangling "one-gun" and it mangles the phrase.
    func testHyphenChainsAreLeftAlone() {
        let text = "the well-known twenty-one-gun salute tradition"
        XCTAssertEqual(SpokenFormNormalizer.writtenForm(text), text)
    }

    /// Documents a known engine limitation rather than endorsing it: the
    /// indefinite article is absorbed into a numeric span, so "a twenty dollar
    /// bill" loses its "a". A definite article survives. If an engine bump ever
    /// fixes this, this test fails and the settings copy can be softened.
    func testKnownLimitationIndefiniteArticleIsAbsorbed() {
        XCTAssertEqual(
            SpokenFormNormalizer.writtenForm("I need a twenty dollar bill"),
            "I need $20 bill"
        )
        XCTAssertEqual(
            SpokenFormNormalizer.writtenForm("the twenty first century problem"),
            "the 21st century problem"
        )
    }
}
