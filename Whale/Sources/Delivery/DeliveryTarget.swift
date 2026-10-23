import Foundation

/// The focused element, read once at the start of a delivery.
struct DeliveryTarget {
    let snapshot: FocusedElementSnapshot
    /// The live accessibility element, when there is one to write to.
    let context: FocusedElementContext?
}
