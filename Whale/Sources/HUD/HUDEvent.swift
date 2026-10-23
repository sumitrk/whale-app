import Foundation

/// What happened, as the HUD hears it. Callers report these; the HUD decides what that means
/// on screen.
enum HUDEvent: Equatable {
    /// Launch is loading History and the model.
    case preparing
    case recording(CaptureIntent, MicLevelMeter)
    case processing(CaptureIntent)
    /// The text reached the Insertion Target, or was left on the clipboard.
    case delivered(DeliveryOutcome)
    /// Done with nothing to say: saved elsewhere, nothing heard, launch finished.
    case finished
    case failed(String)
    /// `replaced` when a newer AI Action took over, which needs no message.
    case cancelled(replaced: Bool)

    static func == (lhs: HUDEvent, rhs: HUDEvent) -> Bool {
        switch (lhs, rhs) {
        case (.preparing, .preparing), (.finished, .finished): true
        case (.recording(let a, let aMeter), .recording(let b, let bMeter)): a == b && aMeter === bMeter
        case (.processing(let a), .processing(let b)): a == b
        case (.delivered(let a), .delivered(let b)): a == b
        case (.failed(let a), .failed(let b)): a == b
        case (.cancelled(let a), .cancelled(let b)): a == b
        default: false
        }
    }
}
