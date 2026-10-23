import AppKit
import ApplicationServices
import CoreGraphics

/// The real system behind `Delivery`: the focused element through accessibility, the general
/// pasteboard, and a ⌘V posted as key events.
@MainActor
final class MacDeliverySystem: DeliverySystem {
    private enum DirectAXInsertionError: LocalizedError {
        case elementUnavailable
        case valueUnavailable
        case selectedRangeUnavailable
        case invalidSelectedRange
        case valueWriteFailed(AXError)

        var errorDescription: String? {
            switch self {
            case .elementUnavailable:
                return "The focused element went away"
            case .valueUnavailable:
                return "AX value is not readable as String"
            case .selectedRangeUnavailable:
                return "AX selected text range is not readable"
            case .invalidSelectedRange:
                return "AX selected text range is out of bounds"
            case .valueWriteFailed(let error):
                return "AX value write failed (\(error.rawValue))"
            }
        }
    }


    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    var canPostEvents: Bool { CGPreflightPostEventAccess() }

    func focusedTarget() -> DeliveryTarget? {
        FocusedElementInspector.focusedElementContext().map {
            DeliveryTarget(snapshot: $0.snapshot, context: $0)
        }
    }

    func insert(_ text: String, into target: DeliveryTarget) throws {
        guard let context = target.context else { throw DirectAXInsertionError.elementUnavailable }
        try Self.insertViaDirectAX(text, into: context)
    }

    var pasteboardChangeCount: Int { pasteboard.changeCount }

    func savePasteboard() -> TextInsertionManager.PasteboardSnapshot {
        .capture(from: pasteboard)
    }

    func restorePasteboard(_ snapshot: TextInsertionManager.PasteboardSnapshot) {
        snapshot.restore(to: pasteboard)
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func pressPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(10_000)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Accessibility

    private static func insertViaDirectAX(_ text: String, into context: FocusedElementContext) throws {
        guard let currentValue = stringValue(of: context.element) else {
            throw DirectAXInsertionError.valueUnavailable
        }
        guard let selectedRange = selectedTextRange(of: context.element) else {
            throw DirectAXInsertionError.selectedRangeUnavailable
        }

        let characterProbe: CharacterProbeResult = currentValue.isEmpty
            ? .unsupported
            : probeFirstCharacter(of: context.element)

        let normalizedState = TextInsertionManager.normalizedEditingState(
            currentValue: currentValue,
            selectedRange: selectedRange,
            placeholderValue: context.placeholderValue,
            numberOfCharacters: context.numberOfCharacters,
            characterProbe: characterProbe
        )

        guard let replacement = TextInsertionManager.replacingSelectedRange(
            in: normalizedState.currentValue,
            selectedRange: normalizedState.selectedRange,
            with: text
        ) else {
            throw DirectAXInsertionError.invalidSelectedRange
        }

        let setValueError = AXUIElementSetAttributeValue(
            context.element,
            kAXValueAttribute as CFString,
            replacement.updatedValue as CFString
        )
        guard setValueError == .success else {
            throw DirectAXInsertionError.valueWriteFailed(setValueError)
        }

        applyCaretSelection(
            replacement.resultingSelectedRange,
            to: context.element
        )
    }

    /// Probes `AXStringForRange({0,1})` to verify whether `AXValue` contains
    /// real content or a phantom placeholder leaked by the AX implementation.
    private static func probeFirstCharacter(of element: AXUIElement) -> CharacterProbeResult {
        var cfRange = CFRange(location: 0, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return .unsupported }

        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForRange" as CFString,
            rangeValue,
            &result
        )

        switch error {
        case .success:
            if let str = result as? String, !str.isEmpty {
                return .content
            }
            return .empty
        case .parameterizedAttributeUnsupported, .attributeUnsupported, .notImplemented:
            return .unsupported
        default:
            return .empty
        }
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func setSelectedTextRange(_ range: NSRange, of element: AXUIElement) -> AXError {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return .failure }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
    }

    /// Some apps reset the caret right after the value changes, so set it again shortly after.
    private static func applyCaretSelection(_ range: NSRange, to element: AXUIElement) {
        let initialError = setSelectedTextRange(range, of: element)
        if initialError != .success {
            DiagnosticLog.log("DirectAX inserted text but could not update caret immediately (\(initialError.rawValue)).")
        }
        Task { @MainActor in
            for delay in [20, 60] {
                try? await Task.sleep(for: .milliseconds(delay))
                let retryError = setSelectedTextRange(range, of: element)
                if retryError != .success {
                    DiagnosticLog.log("DirectAX caret retry failed (\(retryError.rawValue)).")
                }
            }
        }
    }
}
