import Foundation

/// Where the recording pill appears.
enum HUDPosition: String, CaseIterable, Identifiable {
    /// Above the text field being typed into, or beside the pointer when there isn't one.
    case nearInput
    /// Centred along the bottom of the screen the pointer is on, above the Dock.
    case bottomCenter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nearInput: "Next to where you type"
        case .bottomCenter: "Bottom of the screen"
        }
    }
}
