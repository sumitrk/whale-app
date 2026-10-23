import Foundation

/// How the dictation key records.
enum DictationKeyMode: String, CaseIterable, Identifiable {
    /// Hold the key while speaking; releasing it stops.
    case hold
    /// Press once to start, press again to stop.
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: "Hold to talk"
        case .toggle: "Press to start and stop"
        }
    }
}
