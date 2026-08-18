import XCTest
@testable import Whale

final class HotkeyManagerTests: XCTestCase {
    func testFullModeRegistersGlobalAndLocalMonitors() {
        XCTAssertTrue(HotkeyRegistrationMode.full.includesGlobal)
        XCTAssertTrue(HotkeyRegistrationMode.full.includesLocal)
    }

    func testLocalRecoveryModeRegistersOnlyLocalMonitors() {
        XCTAssertFalse(HotkeyRegistrationMode.localRecoveryOnly.includesGlobal)
        XCTAssertTrue(HotkeyRegistrationMode.localRecoveryOnly.includesLocal)
    }

    func testStoppedModeRegistersNoMonitors() {
        XCTAssertFalse(HotkeyRegistrationMode.stopped.includesGlobal)
        XCTAssertFalse(HotkeyRegistrationMode.stopped.includesLocal)
    }

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
