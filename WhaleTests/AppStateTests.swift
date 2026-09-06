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

    func testBrowserGroupIsNotAFieldAnchorEvenWhenMarkedWritable() {
        let pageFrame = NSRect(x: 80, y: 100, width: 1_200, height: 800)

        XCTAssertEqual(
            HUDPlacementPolicy.anchor(
                bundleIdentifier: "company.thebrowser.Browser",
                role: "AXGroup",
                frame: pageFrame,
                caretFrame: NSRect(x: 300, y: 400, width: 0, height: 18),
                isWritable: true,
                isBrowserLike: true
            ),
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

final class HUDDismissalTests: XCTestCase {
    func testOnlyMouseDownEventsDismissFeedback() {
        XCTAssertEqual(
            RecordingIndicatorWindow.feedbackDismissalEvents,
            [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        )
    }

    @MainActor
    func testPasteHintDismissesOnMouseDown() throws {
        let hud = RecordingIndicatorWindow.shared
        hud.showHint(reason: .manualPasteOnly)

        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        NSApplication.shared.sendEvent(event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertNil(hud.contentView)
    }

    /// The HUD is a shared singleton and the host app is still finishing launch when the first
    /// test runs, so its startup path used to call `hide()` on this presentation about half a
    /// second in — the auto-hide never ran, and the old assertion at a fixed 2.3s deadline won
    /// or lost on scheduling noise. Settling first makes the teardown genuinely the 2s timer
    /// (measured: ~2.28s, i.e. 2s + the 0.2s fade + a hop back to the main actor).
    ///
    /// The elapsed time itself is deliberately not asserted: a feedback presentation installs a
    /// *global* mouse-down monitor, so a click anywhere on the machine dismisses the hint early
    /// and would fail a lower bound for reasons that have nothing to do with the code.
    @MainActor
    func testPasteHintAutoHidesAfterTwoSeconds() {
        let hud = RecordingIndicatorWindow.shared
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        hud.showHint(reason: .manualPasteOnly)
        XCTAssertNotNil(hud.contentView, "hint should be on screen as soon as it is shown")

        XCTAssertTrue(
            waitForHUDToClear(hud, within: 4.0),
            "hint should auto-hide on its own"
        )
    }

    /// Spins the main run loop until the HUD has torn its content down, or the budget runs out.
    @MainActor
    private func waitForHUDToClear(
        _ hud: RecordingIndicatorWindow,
        within timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hud.contentView == nil { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return hud.contentView == nil
    }

    @MainActor
    func testPasteHintReplacesAnInFlightHideAnimation() {
        let hud = RecordingIndicatorWindow.shared
        hud.showProcessing()
        hud.hide()
        hud.showHint(reason: .manualPasteOnly)

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertNotNil(hud.contentView)
        XCTAssertGreaterThan(hud.alphaValue, 0.9)
    }
}
