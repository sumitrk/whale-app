import Foundation

/// What delivering text to the Insertion Target actually did.
enum DeliveryOutcome: Equatable, Sendable {
    /// Written into the field through accessibility.
    case inserted
    /// Pasted with a simulated ⌘V; the clipboard is put back afterwards.
    case pasted
    /// Left on the clipboard for the user to paste, for this reason.
    case copied(PasteHintReason)

    var pasteHint: PasteHintReason? {
        if case .copied(let reason) = self { return reason }
        return nil
    }
}
