import XCTest
import FluidAudio
@testable import Whale

// MARK: - Synthetic Sample Helpers

private func silence(seconds: Double) -> [Float] {
    Array(repeating: 0.0, count: Int(VADPolicy.sampleRate * seconds))
}

private func tone(seconds: Double, amplitude: Float = 0.5, frequency: Double = 440) -> [Float] {
    let count = Int(VADPolicy.sampleRate * seconds)
    return (0..<count).map { i in
        amplitude * sin(Float(2.0 * .pi * frequency * Double(i) / VADPolicy.sampleRate))
    }
}

private func noisyTone(seconds: Double, amplitude: Float = 0.5) -> [Float] {
    tone(seconds: seconds, amplitude: amplitude).map {
        $0 + Float.random(in: -0.001...0.001)
    }
}

// MARK: - Speech Span Detection Tests

final class SpeechSpanDetectionTests: XCTestCase {

    func testLeadingAndTrailingSilenceGetsTrimmed() {
        let samples = silence(seconds: 1.0) + tone(seconds: 0.5) + silence(seconds: 1.0)
        let spans = VoiceActivityEditor.detectSpeechSpans(in: samples)

        XCTAssertEqual(spans.count, 1, "Should detect exactly one speech span")

        let speechStart = Int(1.0 * VADPolicy.sampleRate)
        let speechEnd = Int(1.5 * VADPolicy.sampleRate)
        let span = spans[0]
        XCTAssertGreaterThanOrEqual(span.startSample, speechStart - VADPolicy.frameSamples)
        XCTAssertLessThanOrEqual(span.endSample, speechEnd + VADPolicy.frameSamples)
    }

    func testShortPausesStayInsideSingleSpeechSpan() {
        // Two speech segments separated by 300ms gap (< 450ms split threshold)
        let samples = silence(seconds: 0.2)
            + tone(seconds: 0.3)
            + silence(seconds: 0.3) // short gap — should stay inside one span
            + tone(seconds: 0.3)
            + silence(seconds: 0.2)

        let spans = VoiceActivityEditor.detectSpeechSpans(in: samples)

        XCTAssertEqual(spans.count, 1, "Short gap should stay inside one speech span")
    }

    func testLongPauseCreatesSeparateSpans() {
        // Two speech segments separated by 1.2s gap (> 450ms split threshold)
        let samples = silence(seconds: 0.1)
            + tone(seconds: 0.3)
            + silence(seconds: 1.2) // long gap — should NOT merge
            + tone(seconds: 0.3)
            + silence(seconds: 0.1)

        let spans = VoiceActivityEditor.detectSpeechSpans(in: samples)

        XCTAssertEqual(spans.count, 2, "Long gap should produce two separate spans")
    }

    func testAllSilenceProducesNoSpans() {
        let samples = silence(seconds: 2.0)
        let spans = VoiceActivityEditor.detectSpeechSpans(in: samples)

        XCTAssertTrue(spans.isEmpty, "All-silence input should produce no speech spans")
    }

    func testVeryShortUtteranceBelowMinSpeechSpanIsDropped() {
        // 50ms tone is below the 100ms minimum speech span
        let samples = silence(seconds: 0.5) + tone(seconds: 0.05) + silence(seconds: 0.5)
        let spans = VoiceActivityEditor.detectSpeechSpans(in: samples)

        XCTAssertTrue(spans.isEmpty, "Utterance shorter than minSpeechSamples should be dropped")
    }

    func testUtteranceAtMinSpeechSpanSurvives() {
        // 200ms tone should survive the 100ms minimum threshold
        let samples = silence(seconds: 0.3) + tone(seconds: 0.2) + silence(seconds: 0.3)
        let spans = VoiceActivityEditor.detectSpeechSpans(in: samples)

        XCTAssertEqual(spans.count, 1, "200ms utterance should survive 100ms minimum")
    }

    func testLeadingSilenceStillDetectsLaterSoftSpeech() {
        let samples = silence(seconds: 1.5)
            + tone(seconds: 0.35, amplitude: 0.015)
            + silence(seconds: 0.5)
        let spans = VoiceActivityEditor.detectSpeechSpans(in: samples)

        XCTAssertEqual(spans.count, 1, "Leading silence should not prevent later speech detection")
    }

    func testSpeechWithNaturalMicroPausesStaysAsOneSpan() {
        let samples = silence(seconds: 0.2)
            + tone(seconds: 0.14)
            + silence(seconds: 0.08)
            + tone(seconds: 0.12)
            + silence(seconds: 0.09)
            + tone(seconds: 0.13)
            + silence(seconds: 0.2)
        let spans = VoiceActivityEditor.detectSpeechSpans(in: samples)

        XCTAssertEqual(spans.count, 1, "Short pauses inside a phrase should not cut the utterance apart")
    }

    func testEmptyInputProducesNoSpans() {
        let spans = VoiceActivityEditor.detectSpeechSpans(in: [])
        XCTAssertTrue(spans.isEmpty)
    }

    func testTinyInputProducesNoSpans() {
        let spans = VoiceActivityEditor.detectSpeechSpans(in: [0.1, 0.2, 0.3])
        XCTAssertTrue(spans.isEmpty)
    }
}

// MARK: - Waveform Rebuild Tests

final class WaveformRebuildTests: XCTestCase {

    func testLongPauseBetweenSpeechSegmentsIsPreserved() {
        let speech1 = tone(seconds: 0.3)
        let longSilence = silence(seconds: 1.0)
        let speech2 = tone(seconds: 0.3)
        let samples = speech1 + longSilence + speech2

        let spans = [
            SpeechSpan(startSample: 0, endSample: speech1.count),
            SpeechSpan(startSample: speech1.count + longSilence.count, endSample: samples.count),
        ]

        let rebuilt = VoiceActivityEditor.rebuildWaveform(samples: samples, spans: spans)

        let originalDuration = Double(samples.count) / VADPolicy.sampleRate
        let rebuiltDuration = Double(rebuilt.count) / VADPolicy.sampleRate
        XCTAssertGreaterThan(rebuiltDuration, originalDuration * 0.95,
                             "Mid-recording pauses should be preserved when trimming only edges")
    }

    func testShortGapPreservesOriginalAudio() {
        let speech1 = tone(seconds: 0.3)
        let shortSilence = silence(seconds: 0.1) // well below collapse threshold
        let speech2 = tone(seconds: 0.3)
        let samples = speech1 + shortSilence + speech2

        let spans = [
            SpeechSpan(startSample: 0, endSample: speech1.count),
            SpeechSpan(
                startSample: speech1.count + shortSilence.count,
                endSample: samples.count
            ),
        ]

        let rebuilt = VoiceActivityEditor.rebuildWaveform(samples: samples, spans: spans)

        let originalDuration = Double(samples.count) / VADPolicy.sampleRate
        let rebuiltDuration = Double(rebuilt.count) / VADPolicy.sampleRate
        XCTAssertGreaterThan(rebuilt.count, 0)
        XCTAssertGreaterThan(rebuiltDuration, originalDuration * 0.95,
                             "Internal gaps should stay intact when trimming edges only")
    }

    func testTrailingLowEnergyTailIsPreservedByPostRoll() {
        let leadingSilence = silence(seconds: 0.8)
        let loudSpeech = noisyTone(seconds: 0.6, amplitude: 0.35)
        let quietTrailingTail = tone(seconds: 0.85, amplitude: 0.004)
        let trailingSilence = silence(seconds: 0.6)
        let samples = leadingSilence + loudSpeech + quietTrailingTail + trailingSilence

        let spans = VoiceActivityEditor.detectSpeechSpans(in: samples)
        XCTAssertEqual(spans.count, 1)

        let loudSpeechEnd = leadingSilence.count + loudSpeech.count
        XCTAssertLessThanOrEqual(
            spans[0].endSample,
            loudSpeechEnd + VADPolicy.frameSamples,
            "Quiet trailing speech should fall below the detector threshold in this fixture"
        )

        let rebuilt = VoiceActivityEditor.rebuildWaveform(samples: samples, spans: spans)
        let rebuiltDuration = Double(rebuilt.count) / VADPolicy.sampleRate
        XCTAssertGreaterThan(
            rebuiltDuration,
            1.5,
            "Post-roll should preserve trailing low-energy dictation instead of clipping the tail"
        )
    }

    func testNoSpansProducesEmptyOutput() {
        let rebuilt = VoiceActivityEditor.rebuildWaveform(samples: tone(seconds: 1.0), spans: [])
        XCTAssertTrue(rebuilt.isEmpty)
    }

    func testSingleSpanProducesOutput() {
        let samples = tone(seconds: 0.5)
        let spans = [SpeechSpan(startSample: 0, endSample: samples.count)]
        let rebuilt = VoiceActivityEditor.rebuildWaveform(samples: samples, spans: spans)

        XCTAssertGreaterThan(rebuilt.count, 0)
    }
}

// MARK: - Span Merge Tests

final class SpanMergeTests: XCTestCase {

    func testMergeAdjacentSpans() {
        let spans = [
            SpeechSpan(startSample: 0, endSample: 1000),
            SpeechSpan(startSample: 1100, endSample: 2000), // gap = 100 < 2400
        ]

        let merged = VoiceActivityEditor.mergeCloseSpans(spans, maxGap: VADPolicy.mergeGapSamples)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].startSample, 0)
        XCTAssertEqual(merged[0].endSample, 2000)
    }

    func testNoMergeForDistantSpans() {
        let spans = [
            SpeechSpan(startSample: 0, endSample: 1000),
            SpeechSpan(startSample: 10000, endSample: 11000), // gap = 9000 > 2400
        ]

        let merged = VoiceActivityEditor.mergeCloseSpans(spans, maxGap: VADPolicy.mergeGapSamples)

        XCTAssertEqual(merged.count, 2)
    }

    func testMergeEmptyInput() {
        let merged = VoiceActivityEditor.mergeCloseSpans([], maxGap: VADPolicy.mergeGapSamples)
        XCTAssertTrue(merged.isEmpty)
    }

    func testMergeSingleSpan() {
        let spans = [SpeechSpan(startSample: 100, endSample: 500)]
        let merged = VoiceActivityEditor.mergeCloseSpans(spans, maxGap: VADPolicy.mergeGapSamples)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0], spans[0])
    }

    func testMergeChainOfCloseSpans() {
        let spans = [
            SpeechSpan(startSample: 0, endSample: 1000),
            SpeechSpan(startSample: 1500, endSample: 2500),
            SpeechSpan(startSample: 3000, endSample: 4000),
        ]

        let merged = VoiceActivityEditor.mergeCloseSpans(spans, maxGap: VADPolicy.mergeGapSamples)

        XCTAssertEqual(merged.count, 1, "Chain of close spans should merge into one")
        XCTAssertEqual(merged[0].startSample, 0)
        XCTAssertEqual(merged[0].endSample, 4000)
    }
}

// MARK: - Full processWAV Tests

final class VADProcessTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VADProcessTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testAllSilenceFallsBackToOriginal() throws {
        let inputURL = tempDir.appendingPathComponent("silence.wav")
        let outputURL = tempDir.appendingPathComponent("silence-vad.wav")

        try VoiceActivityEditor.writeSamples(silence(seconds: 2.0), to: inputURL)
        let stats = try VoiceActivityEditor.processWAV(inputURL: inputURL, outputURL: outputURL)

        XCTAssertTrue(stats.skipped, "All-silence should cause VAD to skip")
        XCTAssertEqual(stats.spanCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path),
                       "No output file should be written when VAD is skipped")
    }

    func testVeryShortUtteranceFallsBack() throws {
        let inputURL = tempDir.appendingPathComponent("short.wav")
        let outputURL = tempDir.appendingPathComponent("short-vad.wav")

        // 100ms tone surrounded by silence — rebuilt would be very short
        let samples = silence(seconds: 0.5)
            + tone(seconds: 0.1, amplitude: 0.8)
            + silence(seconds: 0.5)
        try VoiceActivityEditor.writeSamples(samples, to: inputURL)
        let stats = try VoiceActivityEditor.processWAV(inputURL: inputURL, outputURL: outputURL)

        XCTAssertTrue(stats.skipped, "Very short utterance should cause VAD to skip")
    }

    func testNormalSpeechTrimsAndWrites() throws {
        let inputURL = tempDir.appendingPathComponent("speech.wav")
        let outputURL = tempDir.appendingPathComponent("speech-vad.wav")

        let samples = silence(seconds: 1.5)
            + noisyTone(seconds: 2.0, amplitude: 0.5)
            + silence(seconds: 1.5)
        try VoiceActivityEditor.writeSamples(samples, to: inputURL)
        let stats = try VoiceActivityEditor.processWAV(inputURL: inputURL, outputURL: outputURL)

        XCTAssertFalse(stats.skipped)
        XCTAssertGreaterThan(stats.spanCount, 0)
        XCTAssertLessThan(stats.retainedDuration, stats.originalDuration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path),
                      "VAD output file should be written")
    }

    func testLongMidRecordingPauseIsPreservedWhileEdgesAreTrimmed() throws {
        let inputURL = tempDir.appendingPathComponent("pause.wav")
        let outputURL = tempDir.appendingPathComponent("pause-vad.wav")

        let samples = silence(seconds: 1.0)
            + noisyTone(seconds: 0.6, amplitude: 0.4)
            + silence(seconds: 1.4)
            + noisyTone(seconds: 0.6, amplitude: 0.4)
            + silence(seconds: 1.0)
        try VoiceActivityEditor.writeSamples(samples, to: inputURL)
        let stats = try VoiceActivityEditor.processWAV(inputURL: inputURL, outputURL: outputURL)

        XCTAssertFalse(stats.skipped)
        XCTAssertEqual(stats.spanCount, 2)
        XCTAssertGreaterThan(stats.retainedDuration, 2.2,
                             "Mid-recording pauses should remain in the VAD output")
        XCTAssertLessThan(stats.retainedDuration, stats.originalDuration,
                          "Leading and trailing silence should still be trimmed")
    }
}

// MARK: - Pipeline Integration Tests

final class VADPipelineIntegrationTests: XCTestCase {

    private let dummyModel = BuiltInModelID.parakeetEnglishV2

    func testVADStageUpdatesContextForMicrophone() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VADPipelineTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("test.wav")
        let samples = silence(seconds: 1.0) + tone(seconds: 2.0) + silence(seconds: 1.0)
        try VoiceActivityEditor.writeSamples(samples, to: inputURL)

        let wavCapture = WAVCapturingStage()
        let pipeline = TranscriptionPipeline(stages: [
            VoiceActivityDetectionStage(),
            wavCapture,
        ])

        let result = try await pipeline.process(
            wavURL: inputURL,
            modelID: dummyModel,
            audioSource: .microphone,
            outputMode: .paste,
            postProcessingSettings: .stub(),
            focusedAppContext: nil
        )

        XCTAssertEqual(result.stagesExecuted, ["VAD", "Capture"])

        let capturedURL = await wavCapture.capturedWavURL
        XCTAssertNotNil(capturedURL)
        XCTAssertNotEqual(capturedURL, inputURL,
                          "TranscriptionStage should receive VAD-produced WAV, not original")

        XCTAssertFalse(result.artifactsToDelete.isEmpty,
                       "VAD should register the derived file for cleanup")
    }

    func testVADStageNoOpForSystemAudio() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VADPipelineTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("test.wav")
        let samples = silence(seconds: 1.0) + tone(seconds: 2.0) + silence(seconds: 1.0)
        try VoiceActivityEditor.writeSamples(samples, to: inputURL)

        let wavCapture = WAVCapturingStage()
        let pipeline = TranscriptionPipeline(stages: [
            VoiceActivityDetectionStage(),
            wavCapture,
        ])

        let result = try await pipeline.process(
            wavURL: inputURL,
            modelID: dummyModel,
            audioSource: .system,
            outputMode: .markdown,
            postProcessingSettings: .stub(),
            focusedAppContext: nil
        )

        let capturedURL = await wavCapture.capturedWavURL
        XCTAssertEqual(capturedURL, inputURL,
                       "System audio should bypass VAD and pass original URL through")
        XCTAssertTrue(result.artifactsToDelete.isEmpty,
                      "No artifacts should be registered for system audio")
    }

    func testVADStageFailureFallsBackCleanly() async throws {
        let badURL = URL(fileURLWithPath: "/nonexistent/path/test.wav")

        let wavCapture = WAVCapturingStage()
        let pipeline = TranscriptionPipeline(stages: [
            VoiceActivityDetectionStage(),
            wavCapture,
        ])

        let result = try await pipeline.process(
            wavURL: badURL,
            modelID: dummyModel,
            audioSource: .microphone,
            outputMode: .paste,
            postProcessingSettings: .stub(),
            focusedAppContext: nil
        )

        let capturedURL = await wavCapture.capturedWavURL
        XCTAssertEqual(capturedURL, badURL,
                       "On VAD failure, original WAV URL should be passed through")
        XCTAssertTrue(result.artifactsToDelete.isEmpty)
    }

    func testPipelineRawAndProcessedTranscriptsBothPopulated() async throws {
        let pipeline = TranscriptionPipeline(stages: [
            MockTranscriptionStage(name: "Transcription", output: "hello world"),
            AppendingStage(name: "Cleanup", suffix: " [clean]"),
        ])

        let result = try await pipeline.process(
            wavURL: URL(fileURLWithPath: "/tmp/test.wav"),
            modelID: dummyModel,
            audioSource: .microphone,
            outputMode: .paste,
            postProcessingSettings: .stub(),
            focusedAppContext: nil
        )

        XCTAssertEqual(result.rawTranscript, "hello world")
        XCTAssertEqual(result.processedTranscript, "hello world [clean]")
    }

    func testPipelineTranscriptionStagePopulatesRawTranscript() async throws {
        let backend = RecordingBackend()
        let service = LocalTranscriptionService(backends: [
            .parakeet: backend,
            .whisper: backend,
        ])

        let pipeline = TranscriptionPipeline(stages: [
            TranscriptionStage(transcriber: service),
            AppendingStage(name: "Postprocess", suffix: " [post]"),
        ])

        let result = try await pipeline.process(
            wavURL: URL(fileURLWithPath: "/tmp/test.wav"),
            modelID: .parakeetEnglishV2,
            audioSource: .microphone,
            outputMode: .paste,
            postProcessingSettings: .stub(),
            focusedAppContext: nil
        )

        XCTAssertEqual(result.rawTranscript, "ok")
        XCTAssertEqual(result.processedTranscript, "ok [post]")
    }
}

// MARK: - Test Helpers

private actor WAVCapturingStage: PipelineStage {
    nonisolated let name = "Capture"
    private(set) var capturedWavURL: URL?

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        capturedWavURL = context.wavURL
        return context
    }
}

private extension TextCleanupSettings {
    static func stub() -> TextCleanupSettings {
        TextCleanupSettings(
            enabled: true,
            cleanupLevel: .light,
            localLLMModelID: .qwen3_0_6b_4bit,
            cleanupPromptOverride: ""
        )
    }
}
