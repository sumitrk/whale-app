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
    static let minSpeechSamples: Int = 1_600 // 100 ms
    static let splitSilenceSamples: Int = 7_200 // 450 ms of silence ends a speech span
    static let mergeGapSamples: Int = 2_400 // 150 ms — only stitch threshold chatter
    static let preRollSamples: Int = 1_920   // 120 ms
    static let postRollSamples: Int = 2_880  // 180 ms
    static let minOutputSamples: Int = 16_800 // ~1.05 s — FluidAudio requires >= 1 s of 16 kHz audio
    static let absoluteFloorDBFS: Float = -48.0
    static let noiseFloorCapDBFS: Float = -48.0 // keep speech-heavy starts from inflating the threshold
    static let noiseMarginDB: Float = 6.0    // margin above noise floor to set speech threshold
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
        let thresholdDB = max(noiseFloor + VADPolicy.noiseMarginDB, VADPolicy.absoluteFloorDBFS)
        let thresholdLinear = dbfsToLinear(thresholdDB)

        print("[VAD] noiseFloor=\(String(format: "%.1f", noiseFloor)) dBFS, "
              + "threshold=\(String(format: "%.1f", thresholdDB)) dBFS")

        var rawSpans: [SpeechSpan] = []
        var speechStart: Int?
        var lastSpeechSample: Int?
        var silenceRunSamples = 0
        var frameStart = 0

        while frameStart + VADPolicy.frameSamples <= count {
            let energy = frameRMS(samples, offset: frameStart, length: VADPolicy.frameSamples)
            let isSpeech = energy >= thresholdLinear
            let frameEnd = min(count, frameStart + VADPolicy.frameSamples)

            if isSpeech && speechStart == nil {
                speechStart = frameStart
            }

            if isSpeech {
                lastSpeechSample = frameEnd
                silenceRunSamples = 0
            } else if let start = speechStart {
                silenceRunSamples += VADPolicy.hopSamples
                if silenceRunSamples >= VADPolicy.splitSilenceSamples {
                    rawSpans.append(
                        SpeechSpan(startSample: start, endSample: lastSpeechSample ?? frameStart)
                    )
                    speechStart = nil
                    lastSpeechSample = nil
                    silenceRunSamples = 0
                }
            }
            frameStart += VADPolicy.hopSamples
        }

        if let start = speechStart {
            rawSpans.append(SpeechSpan(startSample: start, endSample: lastSpeechSample ?? count))
        }

        let merged = mergeCloseSpans(rawSpans, maxGap: VADPolicy.mergeGapSamples)
        let filtered = merged.filter { $0.sampleCount >= VADPolicy.minSpeechSamples }

        print("[VAD] \(rawSpans.count) raw spans → \(merged.count) after merge → \(filtered.count) after min-length")

        return filtered
    }

    /// Rebuilds a waveform by trimming only the leading and trailing silence
    /// around the detected speech. All audio between the first and last speech
    /// span is preserved verbatim, including long pauses.
    static func rebuildWaveform(
        samples: [Float],
        spans: [SpeechSpan]
    ) -> [Float] {
        guard let firstSpan = spans.first, let lastSpan = spans.last else { return [] }

        let start = max(0, firstSpan.startSample - VADPolicy.preRollSamples)
        let end = min(samples.count, lastSpan.endSample + VADPolicy.postRollSamples)
        guard start < end else { return [] }

        return Array(samples[start..<end])
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
        let totalFrames = samples.count / VADPolicy.frameSamples
        guard totalFrames > 0 else { return VADPolicy.absoluteFloorDBFS }

        // Sample up to 200 frames evenly distributed across the entire recording
        // so the estimate isn't contaminated by speech at the start.
        let maxFramesToSample = min(200, totalFrames)
        let step = max(1, totalFrames / maxFramesToSample)

        var energies: [Float] = []
        var frameIdx = 0
        while frameIdx < totalFrames {
            let offset = frameIdx * VADPolicy.frameSamples
            let rms = frameRMS(samples, offset: offset, length: VADPolicy.frameSamples)
            energies.append(linearToDBFS(rms))
            frameIdx += step
        }

        guard !energies.isEmpty else { return VADPolicy.absoluteFloorDBFS }
        energies.sort()

        // 10th percentile of the quietest frames. In a mostly-speech recording
        // this will still pick up the pauses/breaths between words.
        let idx = max(0, energies.count / 10)
        let raw = energies[idx]

        // Cap so a speech-heavy recording (e.g. user starts talking immediately)
        // can't push the threshold unreasonably high.
        return min(raw, VADPolicy.noiseFloorCapDBFS)
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
