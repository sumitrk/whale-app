import Foundation

/// The text a capture produced, with what an intent needs to use it.
struct CaptureTranscript: Sendable {
    let text: String
    let startedAt: Date
    let modelID: BuiltInModelID
    let audioSeconds: Double
}
