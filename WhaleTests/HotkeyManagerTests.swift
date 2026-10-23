import XCTest
@testable import Whale

final class HotkeyManagerTests: XCTestCase {
    func testSyntheticCommandCopyDoesNotCancelModifierOnlyAIAction() {
        XCTAssertFalse(
            HotkeyManager.shouldCancelModifierOnlyAIAction(
                sourceUserData: contextCopyEventUserData
            )
        )
        XCTAssertTrue(
            HotkeyManager.shouldCancelModifierOnlyAIAction(
                sourceUserData: 0
            )
        )
    }

    func testContextCopyMarkerSurvivesNSEventBridge() throws {
        let cgEvent = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                virtualKey: 8,
                keyDown: true
            )
        )
        cgEvent.setIntegerValueField(.eventSourceUserData, value: contextCopyEventUserData)
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))

        XCTAssertFalse(
            HotkeyManager.shouldCancelModifierOnlyAIAction(
                sourceUserData: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            )
        )
    }
}
