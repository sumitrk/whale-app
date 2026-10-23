import Foundation

/// What an intent did with the transcript.
enum CaptureCompletion: Equatable {
    /// Text for the Insertion Target, and what History keeps of it.
    case deliver(_ text: String, instruction: String)
    /// Kept somewhere else (a Transcript file); nothing to insert.
    case saved
}
