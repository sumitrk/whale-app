import AppKit
import ApplicationServices
import CoreGraphics

enum InsertionStrategy: Equatable {
    case directAX
    case simulatedPaste
    case copyOnly(RecordingIndicatorWindow.PasteHintReason)
}

/// Result of probing `AXStringForRange({0,1})` to verify whether a non-empty
/// `AXValue` represents real content or a phantom placeholder leaked by the
/// app's accessibility implementation (common in Electron/Chromium).
enum CharacterProbeResult: Equatable {
    /// The probe returned at least one character — the field has real content.
    case realContent(String)
    /// The attribute is supported but returned no content — the field is
    /// actually empty and `AXValue` contains a phantom placeholder.
    case empty
    /// `AXStringForRange` is not supported by this element; fall back to
    /// other heuristics.
    case unsupported
}

enum TextInsertionManager {

    struct PasteboardSnapshot: Equatable {
        let items: [[String: Data]]

        static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
            let items = (pasteboard.pasteboardItems ?? []).map { item in
                let storedTypes: [(String, Data)] = item.types.compactMap { type in
                    guard let data = item.data(forType: type) else { return nil }
                    return (type.rawValue, data)
                }
                return Dictionary(uniqueKeysWithValues: storedTypes)
            }
            return PasteboardSnapshot(items: items)
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            let restoredItems = items.map { storedTypes -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in storedTypes {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return item
            }
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    struct TextReplacementResult: Equatable {
        let updatedValue: String
        let resultingSelectedRange: NSRange
    }

    struct NormalizedEditingState {
        let currentValue: String
        let selectedRange: CFRange
    }

    private enum DirectAXInsertionError: LocalizedError {
        case valueUnavailable
        case selectedRangeUnavailable
        case invalidSelectedRange
        case valueWriteFailed(AXError)

        var errorDescription: String? {
            switch self {
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

    static func insertionStrategy(
        for snapshot: FocusedElementSnapshot?,
        isAccessibilityTrusted: Bool = AXIsProcessTrusted()
    ) -> InsertionStrategy {
        guard isAccessibilityTrusted else {
            return .copyOnly(.accessibilityMissing)
        }
        guard let snapshot else {
            return .copyOnly(.manualPasteOnly)
        }
        if snapshot.canDirectInsertSafely {
            return .directAX
        }
        if snapshot.isWritableTextTarget {
            return .simulatedPaste
        }
        return .copyOnly(.manualPasteOnly)
    }

    static func replacingSelectedRange(
        in currentValue: String,
        selectedRange: CFRange,
        with text: String
    ) -> TextReplacementResult? {
        guard selectedRange.location >= 0, selectedRange.length >= 0 else { return nil }

        let currentNSString = currentValue as NSString
        let nsRange = NSRange(location: selectedRange.location, length: selectedRange.length)
        guard NSMaxRange(nsRange) <= currentNSString.length else { return nil }

        let updatedValue = currentNSString.replacingCharacters(in: nsRange, with: text)
        let insertedLength = (text as NSString).length
        let resultingSelectedRange = NSRange(location: nsRange.location + insertedLength, length: 0)
        return TextReplacementResult(
            updatedValue: updatedValue,
            resultingSelectedRange: resultingSelectedRange
        )
    }

    static func normalizedEditingState(
        currentValue: String,
        selectedRange: CFRange,
        placeholderValue: String?,
        numberOfCharacters: Int?,
        characterProbe: CharacterProbeResult = .unsupported
    ) -> NormalizedEditingState {
        if let numberOfCharacters, numberOfCharacters == 0, !currentValue.isEmpty {
            return NormalizedEditingState(
                currentValue: "",
                selectedRange: CFRange(location: 0, length: 0)
            )
        }

        if !currentValue.isEmpty, characterProbe == .empty {
            return NormalizedEditingState(
                currentValue: "",
                selectedRange: CFRange(location: 0, length: 0)
            )
        }

        guard let placeholderValue,
              !placeholderValue.isEmpty,
              currentValue == placeholderValue else {
            return NormalizedEditingState(
                currentValue: currentValue,
                selectedRange: selectedRange
            )
        }

        return NormalizedEditingState(
            currentValue: "",
            selectedRange: CFRange(location: 0, length: 0)
        )
    }

    static func shouldRestoreClipboard(
        currentChangeCount: Int,
        expectedTemporaryChangeCount: Int
    ) -> Bool {
        currentChangeCount == expectedTemporaryChangeCount
    }

    @MainActor
    static func insertOrCopy(_ text: String) {
        let focusedElement = FocusedElementInspector.focusedElementContext()
        let snapshot = focusedElement?.snapshot
        let strategy = insertionStrategy(for: snapshot)

        logInsertionDecision(snapshot: snapshot, strategy: strategy)

        switch strategy {
        case .directAX:
            guard let focusedElement else {
                copyToClipboard(text)
                RecordingIndicatorWindow.shared.showHint(reason: .manualPasteOnly)
                return
            }
            do {
                try insertViaDirectAX(text, into: focusedElement)
            } catch {
                let message = "DirectAX insertion failed: \(error.localizedDescription). Falling back to simulated paste."
                print(message)
                DiagnosticLog.log(message)
                simulatedPastePreservingClipboard(text)
            }
        case .simulatedPaste:
            simulatedPastePreservingClipboard(text)
        case .copyOnly(let reason):
            copyToClipboard(text)
            RecordingIndicatorWindow.shared.showHint(reason: reason)
        }
    }

    private static func logInsertionDecision(
        snapshot: FocusedElementSnapshot?,
        strategy: InsertionStrategy
    ) {
        let appName = snapshot?.appName ?? "unknown"
        let bundle = snapshot?.bundleIdentifier ?? "unknown"
        let role = snapshot?.role ?? "nil"
        let subrole = snapshot?.subrole ?? "nil"
        let roleDesc = snapshot?.roleDescription ?? "nil"
        let placeholderValue = snapshot?.placeholderValue ?? "nil"
        let numberOfCharacters = snapshot?.numberOfCharacters.map(String.init) ?? "nil"
        let editable = snapshot?.isEditable ?? false
        let selectedTextRange = snapshot?.supportsSelectedTextRange ?? false
        let hasAXValue = snapshot?.supportsAXValue ?? false
        let canReadAXValue = snapshot?.canReadAXValueAsString ?? false
        let valueSettable = snapshot?.isAXValueSettable ?? false
        let canReadSelectedRange = snapshot?.canReadSelectedTextRange ?? false
        let selectedRangeSettable = snapshot?.isSelectedTextRangeSettable ?? false
        let directInsertBlockers = snapshot?.directInsertBlockers.joined(separator: ",") ?? "none"
        let attrs = snapshot?.attributeNames.joined(separator: ",") ?? "none"
        let strategyLabel: String
        switch strategy {
        case .directAX: strategyLabel = "direct-ax"
        case .simulatedPaste: strategyLabel = "simulated-paste"
        case .copyOnly: strategyLabel = "copy-only"
        }

        let message = "TextInsertion strategy=\(strategyLabel) app=\(appName) bundle=\(bundle) role=\(role) subrole=\(subrole) roleDesc=\(roleDesc) placeholder=\(placeholderValue) numberOfCharacters=\(numberOfCharacters) editable=\(editable) selectedTextRange=\(selectedTextRange) selectedRangeReadable=\(canReadSelectedRange) selectedRangeSettable=\(selectedRangeSettable) hasAXValue=\(hasAXValue) valueReadable=\(canReadAXValue) valueSettable=\(valueSettable) directAXBlockers=[\(directInsertBlockers)] attributes=[\(attrs)]"
        print(message)
        DiagnosticLog.log(message)
    }

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

        let probeLabel: String
        switch characterProbe {
        case .realContent(let ch): probeLabel = "real(\(ch))"
        case .empty: probeLabel = "empty(phantom-placeholder)"
        case .unsupported: probeLabel = "unsupported"
        }

        let normalizedState = normalizedEditingState(
            currentValue: currentValue,
            selectedRange: selectedRange,
            placeholderValue: context.placeholderValue,
            numberOfCharacters: context.numberOfCharacters,
            characterProbe: characterProbe
        )

        let message = "DirectAX probe=\(probeLabel) originalValue=\(currentValue.prefix(60)) normalizedValueLen=\(normalizedState.currentValue.count) normalizedRange={\(normalizedState.selectedRange.location),\(normalizedState.selectedRange.length)}"
        print(message)
        DiagnosticLog.log(message)

        guard let replacement = replacingSelectedRange(
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
                return .realContent(str)
            }
            return .empty
        case .parameterizedAttributeUnsupported, .attributeUnsupported, .notImplemented:
            return .unsupported
        default:
            return .empty
        }
    }

    private static func simulatedPastePreservingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let originalClipboard = PasteboardSnapshot.capture(from: pasteboard)
        copyToClipboard(text, on: pasteboard)
        let temporaryChangeCount = pasteboard.changeCount

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            postCommandV()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if shouldRestoreClipboard(
                    currentChangeCount: pasteboard.changeCount,
                    expectedTemporaryChangeCount: temporaryChangeCount
                ) {
                    originalClipboard.restore(to: pasteboard)
                    let message = "Clipboard restored after simulated paste."
                    print(message)
                    DiagnosticLog.log(message)
                } else {
                    let message = "Clipboard restore skipped because pasteboard changed after Whale wrote it."
                    print(message)
                    DiagnosticLog.log(message)
                }
            }
        }
    }

    private static func copyToClipboard(_ text: String, on pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        usleep(10_000)
        up?.post(tap: .cghidEventTap)
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

    private static func applyCaretSelection(_ range: NSRange, to element: AXUIElement) {
        let initialError = setSelectedTextRange(range, of: element)
        if initialError != .success {
            let message = "DirectAX inserted text but could not update caret immediately (\(initialError.rawValue))."
            print(message)
            DiagnosticLog.log(message)
        }

        for delay in [0.02, 0.08] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let retryError = setSelectedTextRange(range, of: element)
                if retryError != .success {
                    let message = "DirectAX caret retry failed after \(delay)s (\(retryError.rawValue))."
                    print(message)
                    DiagnosticLog.log(message)
                }
            }
        }
    }
}
