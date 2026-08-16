import XCTest
@testable import Whale

final class AppStateActivityTests: XCTestCase {
    func testEarlyPTTReleaseStaysInStartingPhaseAndRequestsStop() {
        var activity = RecordingActivity.starting(mode: .paste, stopRequested: false)

        activity.requestStop()

        XCTAssertEqual(activity, .starting(mode: .paste, stopRequested: true))
        XCTAssertEqual(activity.mode, .paste)
        XCTAssertTrue(activity.isBusy)
        XCTAssertFalse(activity.isRecording)
    }

    func testUnavailableModelUsesTerminalErrorPhase() {
        let activity = RecordingActivity.error("Install the selected model")

        XCTAssertFalse(activity.isBusy)
        XCTAssertFalse(activity.isRecording)
        XCTAssertNil(activity.mode)
    }

    func testRecorderFailureClearsRecordingProjection() {
        let startedAt = Date(timeIntervalSince1970: 123)
        let activity = RecordingActivity.error("Microphone unavailable")

        XCTAssertNotEqual(activity, .recording(mode: .paste, startedAt: startedAt))
        XCTAssertFalse(activity.isRecording)
        XCTAssertFalse(activity.isBusy)
    }

    func testNormalCompletionMovesThroughOneActivityPhaseAtATime() {
        let startedAt = Date(timeIntervalSince1970: 123)
        var activity = RecordingActivity.starting(mode: .markdown, stopRequested: false)
        XCTAssertTrue(activity.isBusy)

        activity = .recording(mode: .markdown, startedAt: startedAt)
        XCTAssertTrue(activity.isRecording)
        XCTAssertEqual(activity.startedAt, startedAt)

        activity = .processing(mode: .markdown)
        XCTAssertTrue(activity.isBusy)
        XCTAssertFalse(activity.isRecording)

        activity = .idle
        XCTAssertFalse(activity.isBusy)
        XCTAssertFalse(activity.isRecording)
        XCTAssertNil(activity.mode)
    }

    func testAIActionLifecycleIsNotRepresentedByRecordingActivity() {
        let activity = RecordingActivity.idle

        XCTAssertFalse(activity.isBusy)
        XCTAssertFalse(activity.isRecording)
        XCTAssertNil(activity.mode)
    }
}
