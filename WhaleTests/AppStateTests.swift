import AppKit
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

final class HUDPlacementPolicyTests: XCTestCase {
    func testWebAreaIsNotAFieldAnchor() {
        let pageFrame = NSRect(x: 80, y: 100, width: 1_200, height: 800)

        XCTAssertEqual(
            HUDPlacementPolicy.anchor(role: "AXWebArea", frame: pageFrame),
            .cursor
        )
    }

    func testGhosttyTextAreaUsesCaretInsteadOfViewport() {
        let viewport = NSRect(x: 80, y: 100, width: 1_200, height: 800)
        let caret = NSRect(x: 480, y: 220, width: 0, height: 18)

        XCTAssertEqual(
            HUDPlacementPolicy.anchor(
                bundleIdentifier: "com.mitchellh.ghostty",
                role: "AXTextArea",
                frame: viewport,
                caretFrame: caret
            ),
            .caret(caret)
        )
    }

    func testGhosttyWithoutCaretFallsBackToCursor() {
        XCTAssertEqual(
            HUDPlacementPolicy.anchor(
                bundleIdentifier: "com.mitchellh.ghostty",
                role: "AXTextArea",
                frame: NSRect(x: 80, y: 100, width: 1_200, height: 800)
            ),
            .cursor
        )
    }

    func testConventionalTextFieldKeepsFieldAnchor() {
        let field = NSRect(x: 200, y: 300, width: 400, height: 44)

        XCTAssertEqual(
            HUDPlacementPolicy.anchor(role: "AXTextField", frame: field),
            .field(field)
        )
    }

    func testCustomEditorWithoutFieldFrameCanUseCaret() {
        let caret = NSRect(x: 480, y: 220, width: 0, height: 18)

        XCTAssertEqual(
            HUDPlacementPolicy.anchor(
                role: "AXGroup",
                frame: nil,
                caretFrame: caret
            ),
            .caret(caret)
        )
    }

    func testCursorOriginOffsetsAndFlipsAtScreenEdges() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let hud = NSSize(width: 100, height: 40)

        XCTAssertEqual(
            HUDPlacementPolicy.cursorOrigin(
                pointer: NSPoint(x: 300, y: 500),
                hudSize: hud,
                visibleFrame: screen
            ),
            NSPoint(x: 312, y: 448)
        )
        XCTAssertEqual(
            HUDPlacementPolicy.cursorOrigin(
                pointer: NSPoint(x: 990, y: 10),
                hudSize: hud,
                visibleFrame: screen
            ),
            NSPoint(x: 878, y: 22)
        )
    }
}
