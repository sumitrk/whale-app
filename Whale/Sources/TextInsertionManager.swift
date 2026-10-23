import AppKit
import ApplicationServices
import CoreGraphics

enum InsertionStrategy: Equatable {
    case directAX
    case simulatedPaste
    case copyOnly(PasteHintReason)

    var diagnosticName: String {
        switch self {
        case .directAX:
            return "directAX"
        case .simulatedPaste:
            return "simulatedPaste"
        case .copyOnly(let reason):
            return "copyOnly(\(reason.diagnosticName))"
        }
    }
}

/// Result of probing `AXStringForRange({0,1})` to verify whether a non-empty
/// `AXValue` represents real content or a phantom placeholder leaked by the
/// app's accessibility implementation (common in Electron/Chromium).
enum CharacterProbeResult: Equatable {
    /// The probe returned at least one character — the field has real content.
    case content
    /// The attribute is supported but returned no content — the field is
    /// actually empty and `AXValue` contains a phantom placeholder.
    case empty
    /// `AXStringForRange` is not supported by this element; fall back to
    /// other heuristics.
    case unsupported
}

/// The decisions behind delivering text, free of side effects: which strategy suits the
/// focused element, how a replacement edits a field's value, and when to restore the
/// clipboard. `Delivery` acts on them.
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

    static func insertionStrategy(
        for snapshot: FocusedElementSnapshot?,
        isAccessibilityTrusted: Bool = AXIsProcessTrusted(),
        canPostEvents: Bool = CGPreflightPostEventAccess()
    ) -> InsertionStrategy {
        guard isAccessibilityTrusted || canPostEvents else {
            return .copyOnly(.accessibilityMissing)
        }
        guard let snapshot else {
            return canPostEvents ? .simulatedPaste : .copyOnly(.manualPasteOnly)
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

    static func diagnosticDescription(for snapshot: FocusedElementSnapshot?) -> String {
        guard let snapshot else { return "none" }
        let appName = snapshot.appName ?? "unknown"
        let bundleID = snapshot.bundleIdentifier ?? "unknown"
        let role = snapshot.role ?? "nil"
        let subrole = snapshot.subrole ?? "nil"
        let blockers = snapshot.directInsertBlockers.isEmpty
            ? "none"
            : snapshot.directInsertBlockers.joined(separator: ",")
        return "app=\(appName) bundle=\(bundleID) role=\(role) subrole=\(subrole) " +
            "writable=\(snapshot.isWritableTextTarget) direct=\(snapshot.canDirectInsertSafely) blockers=\(blockers)"
    }
}
