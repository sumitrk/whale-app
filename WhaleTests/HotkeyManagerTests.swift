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
}
