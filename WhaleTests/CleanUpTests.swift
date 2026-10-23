import FluidAudio
import XCTest
@testable import Whale

final class CleanUpTests: XCTestCase {
    private func clean(
        _ text: String,
        style: CleanUpStyle = .semiFormal,
        lists: Bool = true,
        context: CleanUpContext = .general
    ) -> String {
        RuleCleanUp.clean(text, style: style, allowLists: lists, context: context)
    }

    // MARK: Rules

    func testSpokenBreaks() {
        XCTAssertEqual(clean("Hi there. New paragraph. See you soon."), "Hi there.\n\nSee you soon.")
    }

    func testScratchThatDropsTheSentenceBefore() {
        XCTAssertEqual(clean("Send it now. Actually wait. Scratch that. Send it tomorrow."), "Send it now. Send it tomorrow.")
    }

    func testSelfCorrectionKeepsWhatWasMeant() {
        XCTAssertEqual(clean("Let's meet on Friday, no wait, Thursday."), "Let's meet on Thursday.")
    }

    func testFillersAndStuttersGo() {
        XCTAssertEqual(clean("Um, I think the the plan works."), "I think the plan works.")
    }

    func testSpokenEmailAddress() {
        XCTAssertEqual(clean("Write to emily dot smith at google dot com."), "Write to emily.smith@google.com.")
    }

    func testNumberedList() {
        XCTAssertEqual(
            clean("We need three things. First, milk. Second, eggs. And finally, bread."),
            "We need three things.\n1. Milk\n2. Eggs\n3. Bread"
        )
    }

    func testListsCanBeTurnedOff() {
        XCTAssertFalse(clean("First, milk. Second, eggs.", lists: false).contains("1."))
    }

    func testFormalStyleExpandsContractions() {
        XCTAssertEqual(clean("I'm gonna be late.", style: .formal), "I am going to be late.")
    }

    func testEmailLayoutInMailApps() {
        XCTAssertEqual(
            clean("Hi Sam, the report is ready. Thanks, Priya", context: .email),
            "Hi Sam,\n\nThe report is ready.\n\nThanks,\nPriya"
        )
    }

    func testMailAppsGetEmailContext() {
        XCTAssertEqual(CleanUpContext(bundleID: "com.apple.mail", emailLayout: true), .email)
        XCTAssertEqual(CleanUpContext(bundleID: "com.apple.mail", emailLayout: false), .general)
        XCTAssertEqual(CleanUpContext(bundleID: "com.apple.Notes", emailLayout: true), .general)
    }

    // MARK: Rewrite check

    func testRewriteCheckRejectsNewWords() {
        XCTAssertTrue(RewriteCheck.isPlausible("I am going to be late.", of: "Um, I'm gonna be late."))
        XCTAssertFalse(RewriteCheck.isPlausible(
            "Here is a summary of your meeting notes for today and tomorrow.",
            of: "Send the deck."
        ))
        XCTAssertTrue(RewriteCheck.isPlausible("", of: "Um."))
        XCTAssertFalse(RewriteCheck.isPlausible("", of: "Send the deck to the whole team today."))
    }

    // MARK: Stage

    func testStageLeavesMeetingsAlone() async throws {
        let stage = CleanUpStage(style: .formal, allowLists: true, context: .general)
        let meeting = try await stage.process(context("I'm gonna be late.", source: .system))
        XCTAssertEqual(meeting.transcript, "I'm gonna be late.")
        let dictation = try await stage.process(context("I'm gonna be late.", source: .microphone))
        XCTAssertEqual(dictation.transcript, "I am going to be late.")
    }

    func testStageEmptiesFillerOnlySpeech() async throws {
        let stage = CleanUpStage(style: .semiFormal, allowLists: true, context: .general)
        let result = try await stage.process(context("Um.", source: .microphone))
        XCTAssertEqual(result.transcript, "")
    }

    // MARK: Speech peak

    func testSpeechPeak() {
        XCTAssertEqual(AudioProcessing.speechPeak(of: [Float](repeating: 0, count: 16_000)), 0)
        XCTAssertLessThan(
            AudioProcessing.speechPeak(of: [Float](repeating: 0.001, count: 16_000)),
            AudioProcessing.speechThreshold
        )
        XCTAssertGreaterThan(
            AudioProcessing.speechPeak(of: [Float](repeating: 0.05, count: 16_000)),
            AudioProcessing.speechThreshold
        )
    }

    private func context(_ text: String, source: AudioSource) -> PipelineContext {
        let url = URL(fileURLWithPath: "/dev/null")
        return PipelineContext(
            originalWavURL: url, wavURL: url, modelID: .parakeetEnglishV2, audioSource: source,
            temporaryArtifacts: [], rawTranscript: text, transcript: text, warnings: []
        )
    }
}
