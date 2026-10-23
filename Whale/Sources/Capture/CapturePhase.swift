import Foundation

/// Where the one capture in progress is. There is never more than one.
enum CapturePhase: Equatable {
    case idle
    /// Asked for; the microphone is starting. `stopRequested` remembers a release that came
    /// before the microphone was up.
    case starting(CaptureIntent, stopRequested: Bool)
    case recording(CaptureIntent, startedAt: Date)
    /// Transcribing, then whatever the intent does with the text.
    case processing(CaptureIntent)

    var intent: CaptureIntent? {
        switch self {
        case .idle: nil
        case .starting(let intent, _), .recording(let intent, _), .processing(let intent): intent
        }
    }

    var isBusy: Bool { self != .idle }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
