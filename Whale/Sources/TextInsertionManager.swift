import AppKit
import ApplicationServices
import CoreGraphics

enum PasteDecision: Equatable {
    case autoPaste
    case clipboardOnly(RecordingIndicatorWindow.PasteHintReason)
}

enum TextInsertionManager {

    static func pasteDecision(for snapshot: FocusedElementSnapshot?) -> PasteDecision {
        if snapshot?.isWritableTextTarget == true {
            return .autoPaste
        }
        let reason: RecordingIndicatorWindow.PasteHintReason = AXIsProcessTrusted()
            ? .manualPasteOnly
            : .accessibilityMissing
        return .clipboardOnly(reason)
    }

    @MainActor
    static func insertOrCopy(_ text: String) {
        let focusedElement = FocusedElementInspector.snapshot()
        let decision = pasteDecision(for: focusedElement)

        logPasteDecision(snapshot: focusedElement, decision: decision)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        switch decision {
        case .autoPaste:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let src  = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
                let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
                down?.flags = .maskCommand
                up?.flags   = .maskCommand
                down?.post(tap: .cghidEventTap)
                usleep(10_000)
                up?.post(tap: .cghidEventTap)
            }
        case .clipboardOnly(let reason):
            RecordingIndicatorWindow.shared.showHint(reason: reason)
        }
    }

    private static func logPasteDecision(
        snapshot: FocusedElementSnapshot?,
        decision: PasteDecision
    ) {
        let appName = snapshot?.appName ?? "unknown"
        let bundle = snapshot?.bundleIdentifier ?? "unknown"
        let role = snapshot?.role ?? "nil"
        let subrole = snapshot?.subrole ?? "nil"
        let roleDesc = snapshot?.roleDescription ?? "nil"
        let editable = snapshot?.isEditable ?? false
        let selectedTextRange = snapshot?.supportsSelectedTextRange ?? false
        let hasAXValue = snapshot?.supportsAXValue ?? false
        let attrs = snapshot?.attributeNames.joined(separator: ",") ?? "none"
        let decisionLabel: String
        switch decision {
        case .autoPaste: decisionLabel = "auto-paste"
        case .clipboardOnly: decisionLabel = "clipboard-only"
        }

        let message = "AutoPaste decision=\(decisionLabel) app=\(appName) bundle=\(bundle) role=\(role) subrole=\(subrole) roleDesc=\(roleDesc) editable=\(editable) selectedTextRange=\(selectedTextRange) hasAXValue=\(hasAXValue) attributes=[\(attrs)]"
        print(message)
        DiagnosticLog.log(message)
    }
}
