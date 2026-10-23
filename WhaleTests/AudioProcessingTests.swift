import XCTest
@testable import Whale

final class AudioProcessingTests: XCTestCase {
    func testEmptyInputsProduceNoSamples() {
        XCTAssertTrue(AudioProcessing.mix(system: [], microphone: []).isEmpty)
    }

    func testSystemOnlyInputIsMixedWithSilence() {
        assertSamples(
            AudioProcessing.mix(system: [0.8, -0.4], microphone: []),
            equalTo: [0.4, -0.2]
        )
    }

    func testUnequalInputsAreZeroFilledOnlyWhileMixing() {
        assertSamples(
            AudioProcessing.mix(system: [1.0, 0.5, -0.5], microphone: [0.0, 1.0]),
            equalTo: [0.5, 0.75, -0.25]
        )
    }

    func testCombinedInputsAreAveragedPerSample() {
        assertSamples(
            AudioProcessing.mix(system: [0.8, -0.4], microphone: [0.2, 0.4]),
            equalTo: [0.5, 0.0]
        )
    }

    // MARK: - Resampling

    func testResamplingKeepsTheDurationAtTheNewRate() {
        let oneSecondAt48k = [Float](repeating: 0.25, count: 48_000)
        let resampled = AudioProcessing.resample(oneSecondAt48k, from: 48_000, to: 16_000)

        XCTAssertEqual(resampled.count, 16_000)
        XCTAssertEqual(resampled.first ?? 0, 0.25, accuracy: 0.000_001)
    }

    func testResamplingInterpolatesBetweenSamples() {
        assertSamples(AudioProcessing.resample([0, 1], from: 1, to: 2), equalTo: [0, 0.5, 1, 1])
    }

    // MARK: - Decoding

    func testStereoInt16IsDecodedToMono() throws {
        let frames: [Int16] = [Int16.max, 0, -Int16.max, -Int16.max]
        let data = frames.withUnsafeBytes { Data($0) }
        let format = PCMFormat(sampleRate: 16_000, channels: 2, bitsPerChannel: 16, isFloat: false, isSignedInteger: true)

        let decoded = try XCTUnwrap(AudioProcessing.decode(data, frameCount: 2, format: format))

        assertSamples(decoded, equalTo: [0.5, -1])
    }

    func testFloatAt48kIsDecodedAndResampled() throws {
        let data = [Float](repeating: 0.5, count: 4_800).withUnsafeBytes { Data($0) }
        let format = PCMFormat(sampleRate: 48_000, channels: 1, bitsPerChannel: 32, isFloat: true)

        let decoded = try XCTUnwrap(AudioProcessing.decode(data, frameCount: 4_800, format: format))

        XCTAssertEqual(decoded.count, 1_600)
    }

    func testUnsupportedLayoutsAreRefused() {
        let data = Data(count: 16)
        XCTAssertNil(AudioProcessing.decode(data, frameCount: 4, format: PCMFormat(sampleRate: 16_000, channels: 1, bitsPerChannel: 24, isFloat: false, isSignedInteger: true)))
        XCTAssertNil(AudioProcessing.decode(data, frameCount: 4, format: PCMFormat(sampleRate: 16_000, channels: 2, bitsPerChannel: 32, isFloat: true, isNonInterleaved: true)))
    }

    func testSystemAudioKeepsTheFirstTwoChannels() {
        let frames: [Float] = [1, 0, 9, 0.5, 0.5, 9]
        let mono = frames.withUnsafeBufferPointer { AudioProcessing.downmixSystemAudio($0, channels: 3) }

        assertSamples(mono, equalTo: [0.5, 0.5])
    }

    // MARK: - Preparing a recording

    func testAShortDictationIsPaddedToASecond() throws {
        let prepared = try AudioProcessing.prepare(
            system: [], systemSampleRate: 48_000,
            microphone: [Float](repeating: 0.1, count: 4_000),
            padsShortRecordings: true
        )

        XCTAssertEqual(prepared.capturedCount, 4_000)
        XCTAssertEqual(prepared.samples.count, AudioProcessing.minimumTranscriptionSamples)
        XCTAssertTrue(prepared.wasPadded)
    }

    func testAMeetingIsNotPadded() throws {
        let prepared = try AudioProcessing.prepare(
            system: [Float](repeating: 0.2, count: 3_000), systemSampleRate: 48_000,
            microphone: [Float](repeating: 0.2, count: 1_000),
            padsShortRecordings: false
        )

        XCTAssertEqual(prepared.samples.count, 1_000)
        XCTAssertFalse(prepared.wasPadded)
    }

    func testNothingCapturedIsAnError() {
        XCTAssertThrowsError(try AudioProcessing.prepare(system: [], systemSampleRate: 48_000, microphone: [], padsShortRecordings: true)) {
            guard case RecorderError.noAudioCaptured = $0 else { return XCTFail("\($0)") }
        }
    }

    // MARK: - WAV

    func testWAVIsSixteenBitMonoWithClippedSamples() {
        let data = AudioProcessing.wavData([0, 2, -2])

        XCTAssertEqual(data.count, 44 + 6)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(data.littleEndian(UInt32.self, at: 24), 16_000, "sample rate")
        XCTAssertEqual(data.littleEndian(UInt16.self, at: 22), 1, "channels")
        XCTAssertEqual(data.littleEndian(UInt16.self, at: 34), 16, "bits per sample")
        XCTAssertEqual(data.littleEndian(UInt32.self, at: 40), 6, "data size")
        XCTAssertEqual(Int16(bitPattern: data.littleEndian(UInt16.self, at: 46)), Int16.max)
        XCTAssertEqual(Int16(bitPattern: data.littleEndian(UInt16.self, at: 48)), -Int16.max)
    }

    private func assertSamples(_ actual: [Float], equalTo expected: [Float]) {
        XCTAssertEqual(actual.count, expected.count)
        for (actualSample, expectedSample) in zip(actual, expected) {
            XCTAssertEqual(actualSample, expectedSample, accuracy: 0.000_001)
        }
    }
}

private extension Data {
    func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        T(littleEndian: self[offset..<offset + MemoryLayout<T>.size].withUnsafeBytes { $0.loadUnaligned(as: T.self) })
    }
}
