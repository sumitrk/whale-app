import Foundation

/// Why text went to the clipboard instead of into the Insertion Target, which the HUD's paste
/// hint explains.
enum PasteHintReason: Equatable, Sendable {
    case manualPasteOnly
    case accessibilityMissing

    var diagnosticName: String {
        switch self {
        case .manualPasteOnly: "manualPasteOnly"
        case .accessibilityMissing: "accessibilityMissing"
        }
    }
}
