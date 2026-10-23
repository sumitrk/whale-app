import CoreAudio

/// The layout of one buffer of linear PCM, as a capture source describes it.
struct PCMFormat: Equatable, Sendable {
    let sampleRate: Double
    let channels: Int
    let bitsPerChannel: Int
    let isFloat: Bool
    let isSignedInteger: Bool
    let isNonInterleaved: Bool

    init(
        sampleRate: Double,
        channels: Int,
        bitsPerChannel: Int,
        isFloat: Bool,
        isSignedInteger: Bool = false,
        isNonInterleaved: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel
        self.isFloat = isFloat
        self.isSignedInteger = isSignedInteger
        self.isNonInterleaved = isNonInterleaved
    }

    init(_ description: AudioStreamBasicDescription) {
        self.init(
            sampleRate: description.mSampleRate,
            channels: max(Int(description.mChannelsPerFrame), 1),
            bitsPerChannel: Int(description.mBitsPerChannel),
            isFloat: description.mFormatFlags & kLinearPCMFormatFlagIsFloat != 0,
            isSignedInteger: description.mFormatFlags & kLinearPCMFormatFlagIsSignedInteger != 0,
            isNonInterleaved: description.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        )
    }
}
