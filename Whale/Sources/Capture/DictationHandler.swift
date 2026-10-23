import Foundation

/// Dictation inserts what was said, as said.
@MainActor
final class DictationHandler: CaptureIntentHandler {
    func complete(_ transcript: CaptureTranscript, entry: HistoryEntryHandle?) async throws -> CaptureCompletion {
        .deliver(transcript.text, instruction: transcript.text)
    }
}
