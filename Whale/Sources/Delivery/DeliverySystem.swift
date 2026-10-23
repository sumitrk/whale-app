import Foundation

/// Every system call delivery makes: accessibility, the pasteboard and key events.
/// `MacDeliverySystem` in the app, a fake in tests.
@MainActor
protocol DeliverySystem: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    var canPostEvents: Bool { get }
    func focusedTarget() -> DeliveryTarget?
    /// Writes `text` over the target's selection through accessibility.
    func insert(_ text: String, into target: DeliveryTarget) throws

    var pasteboardChangeCount: Int { get }
    func savePasteboard() -> TextInsertionManager.PasteboardSnapshot
    func restorePasteboard(_ snapshot: TextInsertionManager.PasteboardSnapshot)
    func copy(_ text: String)
    func pressPaste()
}
