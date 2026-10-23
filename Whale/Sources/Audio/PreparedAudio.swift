import Foundation

/// A recording ready for transcription: 16 kHz mono samples.
struct PreparedAudio: Equatable, Sendable {
    let samples: [Float]
    /// Samples that came from the recording, before any silence was added.
    let capturedCount: Int

    var wasPadded: Bool { samples.count > capturedCount }
}
