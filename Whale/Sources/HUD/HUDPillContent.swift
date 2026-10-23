import Foundation

/// What the HUD pill shows. One pill moves between these instead of a new pill per state, so
/// the recording bars turn into the processing wave and the wave into the paste hint in place.
enum HUDPillContent: Equatable {
    case recording(MicLevelMeter)
    case processing
    case pasteHint(PasteHintReason)
    case message(String, isError: Bool)

    /// The live meter while recording or processing, both of which draw the bars.
    var showsWaveform: Bool {
        switch self {
        case .recording, .processing: true
        case .pasteHint, .message: false
        }
    }

    var meter: MicLevelMeter? {
        if case .recording(let meter) = self { return meter }
        return nil
    }

    static func == (lhs: HUDPillContent, rhs: HUDPillContent) -> Bool {
        switch (lhs, rhs) {
        case (.recording(let a), .recording(let b)): a === b
        case (.processing, .processing): true
        case (.pasteHint(let a), .pasteHint(let b)): a == b
        case (.message(let a, let aError), .message(let b, let bError)): a == b && aError == bError
        default: false
        }
    }
}
