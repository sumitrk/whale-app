import AVFoundation
import Foundation

// MARK: - VAD Types

struct SpeechSpan: Equatable, Sendable {
    var startSample: Int
    var endSample: Int

    var sampleCount: Int { endSample - startSample }
}

struct VADStats: Sendable {
    let originalDuration: TimeInterval
    let retainedDuration: TimeInterval
    let spanCount: Int
    let skipped: Bool

    var removedDuration: TimeInterval { originalDuration - retainedDuration }
}

// MARK: - VAD Policy (hardcoded dictation defaults)

enum VADPolicy {
    static let sampleRate: Double = 16_000
    static let frameSamples: Int = 320       // 20 ms at 16 kHz
    static let hopSamples: Int = 160         // 10 ms hop
    static let minSpeechSamples: Int = 2_400 // 150 ms
    static let mergeGapSamples: Int = 4_000  // 250 ms
    static let preRollSamples: Int = 1_920   // 120 ms
    static let postRollSamples: Int = 2_880  // 180 ms
    static let collapseThresholdSamples: Int = 9_600  // 600 ms
    static let spacerSamples: Int = 2_400    // 150 ms spacer replaces long gaps
    static let minOutputSamples: Int = 4_000 // 250 ms — below this, skip VAD
    static let absoluteFloorDBFS: Float = -45.0
    static let noiseMarginDB: Float = 10.0
}

// MARK: - VoiceActivityEditor

enum VoiceActivityEditor {

    /// Loads float samples from a mono 16 kHz WAV file.
    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw VADError.bufferAllocationFailed
        }
        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            throw VADError.noFloatData
        }

        let ptr = channelData[0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
    }

    /// Detects speech spans from raw float samples using frame-energy analysis.
    static func detectSpeechSpans(in samples: [Float]) -> [SpeechSpan] {
        let count = samples.count
        guard count >= VADPolicy.frameSamples else { return [] }

        let noiseFloor = estimateNoiseFloor(samples)
        let thresholdLinear = dbfsToLinear(
            max(noiseFloor + VADPolicy.noiseMarginDB, VADPolicy.absoluteFloorDBFS)
        )

        var rawSpans: [SpeechSpan] = []
        var speechStart: Int?
        var frameStart = 0

        while frameStart + VADPolicy.frameSamples <= count {
            let energy = frameRMS(samples, offset: frameStart, length: VADPolicy.frameSamples)
            let isSpeech = energy >= thresholdLinear

            if isSpeech && speechStart == nil {
                speechStart = frameStart
            } else if !isSpeech, let start = speechStart {
                rawSpans.append(SpeechSpan(startSample: start, endSample: frameStart))
                speechStart = nil
            }
            frameStart += VADPolicy.hopSamples
        }

        if let start = speechStart {
            rawSpans.append(SpeechSpan(startSample: start, endSample: count))
        }

        let filtered = rawSpans.filter { $0.sampleCount >= VADPolicy.minSpeechSamples }
        return mergeCloseSpans(filtered, maxGap: VADPolicy.mergeGapSamples)
    }

    /// Rebuilds a waveform from detected speech spans, collapsing long internal
    /// silence to a fixed spacer and applying pre/post roll padding.
    static func rebuildWaveform(
        samples: [Float],
        spans: [SpeechSpan]
    ) -> [Float] {
        guard !spans.isEmpty else { return [] }

        var output: [Float] = []
        let totalSamples = samples.count

        for (i, span) in spans.enumerated() {
            let paddedStart = max(0, span.startSample - VADPolicy.preRollSamples)
            let paddedEnd = min(totalSamples, span.endSample + VADPolicy.postRollSamples)

            if i > 0 {
                let prevEnd = min(
                    totalSamples,
                    spans[i - 1].endSample + VADPolicy.postRollSamples
                )
                let gapBetween = paddedStart - prevEnd

                if gapBetween >= VADPolicy.collapseThresholdSamples {
                    output.append(contentsOf: [Float](repeating: 0, count: VADPolicy.spacerSamples))
                } else if gapBetween > 0 {
                    let gapStart = prevEnd
                    let gapEnd = paddedStart
                    output.append(contentsOf: samples[gapStart..<gapEnd])
                }
            }

            output.append(contentsOf: samples[paddedStart..<paddedEnd])
        }

        return output
    }

    /// Writes float samples as a mono 16 kHz 16-bit PCM WAV file.
    static func writeSamples(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: VADPolicy.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw VADError.formatCreationFailed
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw VADError.bufferAllocationFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        let dst = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            dst[i] = samples[i]
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: VADPolicy.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    /// Full pipeline: load → detect → rebuild → write. Returns stats.
    static func processWAV(
        inputURL: URL,
        outputURL: URL
    ) throws -> VADStats {
        let samples = try loadSamples(from: inputURL)
        let originalDuration = Double(samples.count) / VADPolicy.sampleRate

        let spans = detectSpeechSpans(in: samples)

        if spans.isEmpty {
            return VADStats(
                originalDuration: originalDuration,
                retainedDuration: originalDuration,
                spanCount: 0,
                skipped: true
            )
        }

        let rebuilt = rebuildWaveform(samples: samples, spans: spans)

        if rebuilt.count < VADPolicy.minOutputSamples {
            return VADStats(
                originalDuration: originalDuration,
                retainedDuration: originalDuration,
                spanCount: spans.count,
                skipped: true
            )
        }

        try writeSamples(rebuilt, to: outputURL)

        let retainedDuration = Double(rebuilt.count) / VADPolicy.sampleRate
        return VADStats(
            originalDuration: originalDuration,
            retainedDuration: retainedDuration,
            spanCount: spans.count,
            skipped: false
        )
    }

    // MARK: - Internal Helpers

    static func mergeCloseSpans(_ spans: [SpeechSpan], maxGap: Int) -> [SpeechSpan] {
        guard var current = spans.first else { return [] }
        var merged: [SpeechSpan] = []

        for span in spans.dropFirst() {
            if span.startSample - current.endSample <= maxGap {
                current.endSample = span.endSample
            } else {
                merged.append(current)
                current = span
            }
        }
        merged.append(current)
        return merged
    }

    private static func frameRMS(_ samples: [Float], offset: Int, length: Int) -> Float {
        var sumSq: Float = 0
        let end = min(offset + length, samples.count)
        for i in offset..<end {
            sumSq += samples[i] * samples[i]
        }
        let count = Float(end - offset)
        guard count > 0 else { return 0 }
        return (sumSq / count).squareRoot()
    }

    private static func estimateNoiseFloor(_ samples: [Float]) -> Float {
        let analysisFrames = min(50, samples.count / VADPolicy.frameSamples)
        guard analysisFrames > 0 else { return VADPolicy.absoluteFloorDBFS }

        var energies: [Float] = []
        for i in 0..<analysisFrames {
            let offset = i * VADPolicy.frameSamples
            let rms = frameRMS(samples, offset: offset, length: VADPolicy.frameSamples)
            if rms > 0 {
                energies.append(linearToDBFS(rms))
            }
        }

        guard !energies.isEmpty else { return VADPolicy.absoluteFloorDBFS }
        energies.sort()

        let percentile10 = energies[max(0, energies.count / 10)]
        return percentile10
    }

    private static func linearToDBFS(_ linear: Float) -> Float {
        guard linear > 0 else { return -100 }
        return 20.0 * log10(linear)
    }

    private static func dbfsToLinear(_ dbfs: Float) -> Float {
        pow(10.0, dbfs / 20.0)
    }
}

// MARK: - Errors

enum VADError: Error, LocalizedError {
    case bufferAllocationFailed
    case noFloatData
    case formatCreationFailed

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: return "Failed to allocate audio buffer for VAD"
        case .noFloatData: return "WAV file does not contain float sample data"
        case .formatCreationFailed: return "Failed to create audio format for VAD output"
        }
    }
}
