import AppKit
import ApplicationServices

struct FocusedElementContext {
    let snapshot: FocusedElementSnapshot
    let element: AXUIElement
    let placeholderValue: String?
    let numberOfCharacters: Int?
}

struct FocusedElementSnapshot {
    let appName: String?
    let bundleIdentifier: String?
    let role: String?
    let subrole: String?
    let roleDescription: String?
    let placeholderValue: String?
    let numberOfCharacters: Int?
    let isEditable: Bool
    let supportsSelectedTextRange: Bool
    let supportsAXValue: Bool
    let canReadAXValueAsString: Bool
    let isAXValueSettable: Bool
    let canReadSelectedTextRange: Bool
    let isSelectedTextRangeSettable: Bool
    let frame: NSRect?
    /// AX attributes found on the focused element (for diagnostics).
    let attributeNames: [String]

    private static let knownTextRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        "AXWebArea",
    ]

    /// Bundle IDs of known Chromium-based browsers / Electron apps.
    private static let chromiumBundlePrefixes: [String] = [
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
        "com.arc.Arc",
    ]

    private var isBrowserApp: Bool {
        guard let bundle = bundleIdentifier else { return false }
        return Self.chromiumBundlePrefixes.contains(where: { bundle.hasPrefix($0) })
    }

    var prefersSimulatedPasteOverDirectAX: Bool {
        isBrowserApp || hasChromiumAccessibilityMarkers
    }

    var canDirectInsertSafely: Bool {
        isWritableTextTarget
            && !prefersSimulatedPasteOverDirectAX
            && canReadAXValueAsString
            && isAXValueSettable
            && canReadSelectedTextRange
            && isSelectedTextRangeSettable
    }

    var directInsertBlockers: [String] {
        var blockers: [String] = []
        if !isWritableTextTarget { blockers.append("not-writable-target") }
        if prefersSimulatedPasteOverDirectAX { blockers.append("browser-like-editor") }
        if !canReadAXValueAsString { blockers.append("value-not-readable-as-string") }
        if !isAXValueSettable { blockers.append("value-not-settable") }
        if !canReadSelectedTextRange { blockers.append("selected-range-not-readable") }
        if !isSelectedTextRangeSettable { blockers.append("selected-range-not-settable") }
        return blockers
    }

    var isWritableTextTarget: Bool {
        // 1. Classic native text roles
        if let role, Self.knownTextRoles.contains(role) {
            return true
        }
        // 2. Element reports itself as editable or supports text selection
        if isEditable || supportsSelectedTextRange {
            return true
        }
        // 3. Chromium browsers: the focused element is often an AXGroup
        //    inside an AXWebArea. Check for text-input indicators.
        if isBrowserApp {
            // If the element has AXValue (holds text) or AXSelectedTextRange
            // it is almost certainly an editable web field.
            if supportsAXValue || supportsSelectedTextRange {
                return true
            }
            // Chromium may report role=AXGroup, subrole=nil for
            // contenteditable divs. When we're in a known browser and the
            // element has a role description containing "text" or "edit"
            // that's enough to trust it.
            if let rd = roleDescription?.lowercased(),
               rd.contains("text") || rd.contains("edit") {
                return true
            }
            // Final heuristic: if we're in a browser and the focused
            // element is an AXGroup (common for contenteditable), allow it.
            // This matches address bars and web text inputs alike.
            if role == "AXGroup" {
                return true
            }
        }
        return false
    }

    private var hasChromiumAccessibilityMarkers: Bool {
        let chromiumMarkers: Set<String> = [
            "ChromeAXNodeId",
            "AXDOMIdentifier",
            "AXDOMClassList",
            "AXStartTextMarker",
            "AXEndTextMarker",
            "AXSelectedTextMarkerRange",
        ]
        return !chromiumMarkers.isDisjoint(with: Set(attributeNames))
    }
}

enum FocusedElementInspector {
    static func snapshot() -> FocusedElementSnapshot? {
        focusedElementContext()?.snapshot
    }

    static func focusedElementContext() -> FocusedElementContext? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
              let focusedRef else { return nil }

        let element = focusedRef as! AXUIElement
        let names = attributeNames(for: element)

        let role = stringAttribute(kAXRoleAttribute as CFString, of: element)
        let subrole = stringAttribute(kAXSubroleAttribute as CFString, of: element)
        let roleDescription = stringAttribute(kAXRoleDescriptionAttribute as CFString, of: element)
        let placeholderValue = stringAttribute("AXPlaceholderValue" as CFString, of: element)
        let numberOfCharacters = intAttribute("AXNumberOfCharacters" as CFString, of: element)
        let isEditable = boolAttribute("AXEditable" as CFString, of: element)
        let supportsSelectedTextRange = names.contains(kAXSelectedTextRangeAttribute as String)
        let supportsAXValue = names.contains(kAXValueAttribute as String)
        let canReadAXValueAsString = stringAttribute(kAXValueAttribute as CFString, of: element) != nil
        let isAXValueSettable = supportsAXValue
            && isAttributeSettable(kAXValueAttribute as CFString, of: element)
        let canReadSelectedTextRange = selectedTextRangeAttribute(of: element) != nil
        let isSelectedTextRangeSettable = supportsSelectedTextRange
            && isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, of: element)
        let frame = frameAttribute(of: element)

        let snapshot = FocusedElementSnapshot(
            appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            role: role,
            subrole: subrole,
            roleDescription: roleDescription,
            placeholderValue: placeholderValue,
            numberOfCharacters: numberOfCharacters,
            isEditable: isEditable,
            supportsSelectedTextRange: supportsSelectedTextRange,
            supportsAXValue: supportsAXValue,
            canReadAXValueAsString: canReadAXValueAsString,
            isAXValueSettable: isAXValueSettable,
            canReadSelectedTextRange: canReadSelectedTextRange,
            isSelectedTextRangeSettable: isSelectedTextRangeSettable,
            frame: frame,
            attributeNames: names
        )

        return FocusedElementContext(
            snapshot: snapshot,
            element: element,
            placeholderValue: placeholderValue,
            numberOfCharacters: numberOfCharacters
        )
    }

    private static func attributeNames(for element: AXUIElement) -> [String] {
        var namesRef: CFArray?
        guard AXUIElementCopyAttributeNames(element, &namesRef) == .success,
              let names = namesRef as? [String] else { return [] }
        return names
    }

    private static func stringAttribute(_ name: CFString, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value as? String
    }

    private static func boolAttribute(_ name: CFString, of element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let value else { return false }

        if let boolValue = value as? Bool {
            return boolValue
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private static func intAttribute(_ name: CFString, of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
              let value else { return nil }

        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func isAttributeSettable(_ name: CFString, of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, name, &settable) == .success else { return false }
        return settable.boolValue
    }

    private static func selectedTextRangeAttribute(of element: AXUIElement) -> CFRange? {
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

    private static func frameAttribute(of element: AXUIElement) -> NSRect? {
        var frameRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameRef) == .success,
              let frameRef,
              CFGetTypeID(frameRef) == AXValueGetTypeID() else { return nil }

        var axRect = CGRect.zero
        guard AXValueGetValue(frameRef as! AXValue, .cgRect, &axRect) else { return nil }

        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(
            x: axRect.origin.x,
            y: screenHeight - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }
}
