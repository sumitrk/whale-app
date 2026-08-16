import XCTest
@testable import Whale

final class AudioRecorderMixingTests: XCTestCase {
    func testEmptyInputsProduceNoSamples() {
        XCTAssertTrue(AudioRecorder.mixSamples(system: [], microphone: []).isEmpty)
    }

    func testSystemOnlyInputIsMixedWithSilence() {
        assertSamples(
            AudioRecorder.mixSamples(system: [0.8, -0.4], microphone: []),
            equalTo: [0.4, -0.2]
        )
    }

    func testMicrophoneOnlyInputIsMixedWithSilence() {
        assertSamples(
            AudioRecorder.mixSamples(system: [], microphone: [0.6, -0.2]),
            equalTo: [0.3, -0.1]
        )
    }

    func testUnequalInputsAreZeroFilledOnlyWhileMixing() {
        assertSamples(
            AudioRecorder.mixSamples(system: [1.0, 0.5, -0.5], microphone: [0.0, 1.0]),
            equalTo: [0.5, 0.75, -0.25]
        )
    }

    func testCombinedInputsAreAveragedPerSample() {
        assertSamples(
            AudioRecorder.mixSamples(system: [0.8, -0.4], microphone: [0.2, 0.4]),
            equalTo: [0.5, 0.0]
        )
    }

    private func assertSamples(_ actual: [Float], equalTo expected: [Float]) {
        XCTAssertEqual(actual.count, expected.count)
        for (actualSample, expectedSample) in zip(actual, expected) {
            XCTAssertEqual(actualSample, expectedSample, accuracy: 0.000_001)
        }
    }
}
