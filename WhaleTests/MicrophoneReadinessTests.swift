import XCTest
@testable import Whale

final class MicrophoneReadinessTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testAWiredMicrophoneIsReadyAtItsFirstBuffer() {
        var readiness = MicrophoneReadiness()
        readiness.begin(.standard, at: start, isRestart: false)

        XCTAssertTrue(readiness.receivedUsableBuffer(at: start))
        XCTAssertFalse(readiness.receivedUsableBuffer(at: start + 0.01), "ready is reported once")
        XCTAssertFalse(readiness.needsRestart)
    }

    func testBluetoothWaitsForThreeBuffersAfterAQuietPeriod() {
        var readiness = MicrophoneReadiness()
        readiness.begin(.bluetooth, at: start, isRestart: false)

        XCTAssertFalse(readiness.receivedUsableBuffer(at: start + 0.30))
        XCTAssertFalse(readiness.receivedUsableBuffer(at: start + 0.31))
        XCTAssertTrue(readiness.receivedUsableBuffer(at: start + 0.32))
    }

    func testBluetoothBuffersDuringTheSwitchDontCount() {
        var readiness = MicrophoneReadiness()
        readiness.begin(.bluetooth, at: start, isRestart: false)

        for offset in [0.05, 0.10, 0.15, 0.20] {
            XCTAssertFalse(readiness.receivedUsableBuffer(at: start + offset), "too soon after the start")
        }
        XCTAssertTrue(readiness.receivedUsableBuffer(at: start + 0.26))
    }

    func testAnUnsettledBluetoothMicrophoneAsksForARestart() {
        var readiness = MicrophoneReadiness()
        readiness.begin(.bluetooth, at: start, isRestart: false)
        XCTAssertTrue(readiness.needsRestart)

        readiness.restarting(at: start + 0.75)
        XCTAssertEqual(readiness.restartCount, 1)
        readiness.clear()
        readiness.begin(.bluetooth, at: start + 0.80, isRestart: true)
        XCTAssertEqual(readiness.restartCount, 1, "a restart keeps the count")

        _ = readiness.receivedUsableBuffer(at: start + 1.10)
        _ = readiness.receivedUsableBuffer(at: start + 1.11)
        XCTAssertTrue(readiness.receivedUsableBuffer(at: start + 1.12))
        XCTAssertFalse(readiness.needsRestart)
    }

    func testANewRecordingStartsCountingAgain() {
        var readiness = MicrophoneReadiness()
        readiness.begin(.bluetooth, at: start, isRestart: false)
        readiness.restarting(at: start + 1)
        readiness.begin(.bluetooth, at: start + 2, isRestart: false)

        XCTAssertEqual(readiness.restartCount, 0)
    }

    func testOnlyBluetoothRestarts() {
        var readiness = MicrophoneReadiness()
        readiness.begin(.standard, at: start, isRestart: false)
        readiness.restarting(at: start + 1)

        XCTAssertEqual(readiness.restartCount, 0)
        XCTAssertFalse(readiness.needsRestart)
    }
}
