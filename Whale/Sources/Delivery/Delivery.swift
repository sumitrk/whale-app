import Foundation

/// Delivers text to the Insertion Target and says how: inserted directly, pasted, or left on
/// the clipboard with the reason. Chooses the strategy from the focused element and the
/// permissions Whale has; every system call goes through `DeliverySystem`.
@MainActor
final class Delivery {
    static let shared = Delivery(system: MacDeliverySystem())

    private let system: DeliverySystem
    private let pasteDelay: Duration
    private let restoreDelay: Duration
    /// The simulated paste and clipboard restore, which finish after `deliver` returns.
    private(set) var pendingPaste: Task<Void, Never>?

    /// - Parameters:
    ///   - pasteDelay: before ⌘V, so the target app sees the new clipboard.
    ///   - restoreDelay: after ⌘V, before putting the user's clipboard back.
    init(
        system: DeliverySystem,
        pasteDelay: Duration = .milliseconds(100),
        restoreDelay: Duration = .milliseconds(350)
    ) {
        self.system = system
        self.pasteDelay = pasteDelay
        self.restoreDelay = restoreDelay
    }

    func deliver(_ text: String) -> DeliveryOutcome {
        let target = system.focusedTarget()
        let strategy = TextInsertionManager.insertionStrategy(
            for: target?.snapshot,
            isAccessibilityTrusted: system.isAccessibilityTrusted,
            canPostEvents: system.canPostEvents
        )
        DiagnosticLog.log(
            "[Paste] strategy=\(strategy.diagnosticName) textLength=\(text.count) trusted=\(system.isAccessibilityTrusted) " +
            "canPostEvents=\(system.canPostEvents) target=\(TextInsertionManager.diagnosticDescription(for: target?.snapshot))"
        )

        switch strategy {
        case .directAX:
            if let target {
                do {
                    try system.insert(text, into: target)
                    DiagnosticLog.log("[Paste] Inserted transcript via DirectAX.")
                    return .inserted
                } catch {
                    DiagnosticLog.log("DirectAX insertion failed: \(error.localizedDescription). Falling back to simulated paste.")
                }
            }
            paste(text)
            return .pasted
        case .simulatedPaste:
            DiagnosticLog.log("[Paste] Using simulated Command-V paste.")
            paste(text)
            return .pasted
        case .copyOnly(let reason):
            system.copy(text)
            DiagnosticLog.log("[Paste] Copied transcript without auto-paste. reason=\(reason.diagnosticName)")
            return .copied(reason)
        }
    }

    /// Pastes through the clipboard, then puts the user's clipboard back, unless something
    /// else wrote to it in the meantime.
    private func paste(_ text: String) {
        let original = system.savePasteboard()
        system.copy(text)
        let temporaryChangeCount = system.pasteboardChangeCount
        let system = system
        let pasteDelay = pasteDelay
        let restoreDelay = restoreDelay
        pendingPaste = Task {
            try? await Task.sleep(for: pasteDelay)
            system.pressPaste()
            try? await Task.sleep(for: restoreDelay)
            if TextInsertionManager.shouldRestoreClipboard(
                currentChangeCount: system.pasteboardChangeCount,
                expectedTemporaryChangeCount: temporaryChangeCount
            ) {
                system.restorePasteboard(original)
                DiagnosticLog.log("Clipboard restored after simulated paste.")
            } else {
                DiagnosticLog.log("Clipboard restore skipped because pasteboard changed after Whale wrote it.")
            }
        }
    }
}
