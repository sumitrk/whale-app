import Foundation

/// The pure half of recording: buffers in, a 16 kHz mono WAV out. Decoding, downmixing,
/// resampling, mixing the microphone with system audio, padding and WAV encoding, with no
/// devices involved, so all of it is testable with made-up samples.
enum AudioProcessing {
    /// What the transcription models take.
    static let sampleRate: Double = 16_000
    /// Models misbehave on less than a second of audio, so a short dictation is padded to it.
    static let minimumTranscriptionSamples = 16_000

    // MARK: - Decoding

    /// Decodes one interleaved microphone buffer to mono at `sampleRate`. Nil for a layout
    /// the recorder doesn't ask for.
    static func decode(_ data: Data, frameCount: Int, format: PCMFormat) -> [Float]? {
        guard frameCount > 0, !format.isNonInterleaved else { return nil }
        let mono: [Float]
        if format.isFloat, format.bitsPerChannel == 32 {
            mono = decodeFloat32(data, frameCount: frameCount, channels: format.channels)
        } else if format.isSignedInteger, format.bitsPerChannel == 16 {
            mono = decodeInt16(data, frameCount: frameCount, channels: format.channels)
        } else {
            return nil
        }
        guard format.sampleRate > 0 else { return mono }
        return resample(mono, from: format.sampleRate, to: sampleRate)
    }

    static func decodeFloat32(_ data: Data, frameCount: Int, channels: Int) -> [Float] {
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float.self)
            let frames = min(frameCount, values.count / max(channels, 1))
            if channels == 1 { return Array(values.prefix(frames)) }
            return (0..<frames).map { frame in
                let base = frame * channels
                return (0..<channels).reduce(Float(0)) { $0 + values[base + $1] } / Float(channels)
            }
        }
    }

    static func decodeInt16(_ data: Data, frameCount: Int, channels: Int) -> [Float] {
        data.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            let frames = min(frameCount, values.count / max(channels, 1))
            let scale = Float(Int16.max)
            if channels == 1 { return values.prefix(frames).map { Float($0) / scale } }
            return (0..<frames).map { frame in
                let base = frame * channels
                return (0..<channels).reduce(Float(0)) { $0 + Float(values[base + $1]) / scale } / Float(channels)
            }
        }
    }

    /// System audio arrives as interleaved float frames; keeps the average of the first two
    /// channels of each frame.
    static func downmixSystemAudio(_ samples: UnsafeBufferPointer<Float>, channels: Int) -> [Float] {
        guard channels >= 2 else { return Array(samples) }
        var mono = [Float]()
        mono.reserveCapacity(samples.count / channels)
        var index = 0
        while index + 1 < samples.count {
            mono.append((samples[index] + samples[index + 1]) / 2)
            index += channels
        }
        return mono
    }

    // MARK: - Levels

    /// The HUD's meter reading for a buffer: RMS, scaled so speech fills the bars.
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return min(1, sqrt(sum / Float(samples.count)) * 40)
    }

    // MARK: - Resampling and mixing

    /// Linear interpolation; enough for speech going to a 16 kHz model.
    static func resample(_ input: [Float], from source: Double, to target: Double) -> [Float] {
        guard source != target, !input.isEmpty else { return input }
        let ratio = target / source
        let outputCount = Int(Double(input.count) * ratio)
        var output = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = Double(index) / ratio
            let low = Int(position)
            let high = min(low + 1, input.count - 1)
            let fraction = Float(position - Double(low))
            output[index] = input[low] * (1 - fraction) + input[high] * fraction
        }
        return output
    }

    /// Averages the two sources sample by sample; the shorter one counts as silence past its end.
    static func mix(system: [Float], microphone: [Float]) -> [Float] {
        let count = max(system.count, microphone.count)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let systemSample = index < system.count ? system[index] : 0
            let microphoneSample = index < microphone.count ? microphone[index] : 0
            return (systemSample + microphoneSample) / 2
        }
    }

    /// Everything one recording needs before it's written: system audio brought to 16 kHz,
    /// mixed with the microphone, and a short microphone-only recording padded with silence.
    static func prepare(
        system: [Float],
        systemSampleRate: Double,
        microphone: [Float],
        padsShortRecordings: Bool
    ) throws -> PreparedAudio {
        let mixed = mix(system: resample(system, from: systemSampleRate, to: sampleRate), microphone: microphone)
        guard !mixed.isEmpty else { throw RecorderError.noAudioCaptured }
        guard padsShortRecordings, mixed.count < minimumTranscriptionSamples else {
            return PreparedAudio(samples: mixed, capturedCount: mixed.count)
        }
        let padding = [Float](repeating: 0, count: minimumTranscriptionSamples - mixed.count)
        return PreparedAudio(samples: mixed + padding, capturedCount: mixed.count)
    }

    // MARK: - WAV

    /// A 16-bit PCM mono WAV file, samples clipped to [-1, 1].
    static func wavData(_ samples: [Float], sampleRate: Int = Int(sampleRate)) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * 2))
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(UInt32(dataSize))
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * Float(Int16.max))
            data.appendLittleEndian(UInt16(bitPattern: value))
        }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
