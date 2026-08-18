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

    var isSecureTextField: Bool {
        subrole == "AXSecureTextField" || role == "AXSecureTextField"
    }

    private static let knownTextRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
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

    private var isBrowserLike: Bool {
        isBrowserApp || hasChromiumAccessibilityMarkers
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
        if isSecureTextField { return false }
        if isEditable { return true }
        // A web area or landmark is page content, not an insertion target.
        if role == "AXWebArea" || subrole?.hasPrefix("AXLandmark") == true {
            return false
        }
        // 1. Classic native text roles
        if let role, Self.knownTextRoles.contains(role) {
            return true
        }
        // 2. Native custom editors commonly expose a writable selection range.
        if !isBrowserLike && supportsSelectedTextRange {
            return true
        }
        // 3. Chromium browsers: the focused element is often an AXGroup
        //    inside an AXWebArea. Check for text-input indicators.
        if isBrowserLike {
            // Chromium contenteditable nodes are often AXGroup values rather
            // than conventional text roles.
            if role == "AXGroup" && subrole == nil && supportsAXValue {
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
            // Chromium contenteditable nodes can be AXGroup with a writable
            // selected-text range but no conventional text role.
            if role == "AXGroup" && subrole == nil && supportsSelectedTextRange {
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
    private struct FocusResolution {
        let element: AXUIElement
        let path: String
    }

    static func snapshot() -> FocusedElementSnapshot? {
        focusedElementContext()?.snapshot
    }

    static func focusedElementContext(logDiagnostics: Bool = true) -> FocusedElementContext? {
        guard AXIsProcessTrusted() else {
            if logDiagnostics {
                DiagnosticLog.log("[Focus] AXIsProcessTrusted returned false.")
            }
            return nil
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let appName = frontmostApp?.localizedName ?? "unknown"
        let bundleIdentifier = frontmostApp?.bundleIdentifier ?? "unknown"
        let system = AXUIElementCreateSystemWide()

        guard let resolution = resolveFocusedElement(
            system: system,
            frontmostPID: frontmostApp?.processIdentifier,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            logDiagnostics: logDiagnostics
        ) else {
            return nil
        }

        let element = resolution.element
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
            appName: appName,
            bundleIdentifier: bundleIdentifier,
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

    static func hudAnchor() -> HUDAnchor {
        guard let context = focusedElementContext(logDiagnostics: false) else { return .cursor }
        let snapshot = context.snapshot
        return HUDPlacementPolicy.anchor(
            bundleIdentifier: snapshot.bundleIdentifier,
            role: snapshot.role,
            frame: snapshot.frame,
            caretFrame: caretFrame(of: context.element),
            isWritable: snapshot.isWritableTextTarget
        )
    }

    static func selectedText(in context: FocusedElementContext) -> String? {
        let elements = selectionElements(startingAt: context.element)
        var markerRanges: [CFTypeRef] = []

        for element in elements {
            if let selectedText = stringAttribute(kAXSelectedTextAttribute as CFString, of: element),
               !selectedText.isEmpty {
                return selectedText
            }

            if let selectedMarkerRange = attributeValue(
                "AXSelectedTextMarkerRange" as CFString,
                of: element
            ) {
                markerRanges.append(selectedMarkerRange)
            }

            if let selectedRange = selectedTextRangeAttribute(of: element),
               selectedRange.length > 0,
               let selectedText = text(for: selectedRange, in: element),
               !selectedText.isEmpty {
                return selectedText
            }
        }

        // Browser engines may expose AXSelectedTextMarkerRange on a leaf node
        // while serving AXStringForTextMarkerRange from a shared parent.
        for markerRange in markerRanges {
            for element in elements {
                if let selectedText = text(for: markerRange, in: element),
                   !selectedText.isEmpty {
                    return selectedText
                }
            }
        }
        return nil
    }

    static func selectedTextRange(in context: FocusedElementContext) -> CFRange? {
        selectedTextRangeAttribute(of: context.element)
    }

    private static func resolveFocusedElement(
        system: AXUIElement,
        frontmostPID: pid_t?,
        appName: String,
        bundleIdentifier: String,
        logDiagnostics: Bool
    ) -> FocusResolution? {
        var attempts: [String] = []

        if let frontmostPID,
           let element = focusedElement(
                from: AXUIElementCreateApplication(frontmostPID),
                label: "frontmostApp(pid=\(frontmostPID))",
                attempts: &attempts
           ) {
            if logDiagnostics {
                DiagnosticLog.log("[Focus] Resolved focused element via frontmost app lookup for \(appName) (\(bundleIdentifier)).")
            }
            return FocusResolution(element: element, path: "frontmostApp")
        }

        var focusedAppRef: CFTypeRef?
        let focusedAppError = copyAttributeValueWithRetries(
            from: system,
            attribute: kAXFocusedApplicationAttribute as CFString,
            value: &focusedAppRef
        )
        if focusedAppError == .success, let focusedAppRef {
            let appElement = focusedAppRef as! AXUIElement
            if let element = focusedElement(
                from: appElement,
                label: "systemFocusedApplication",
                attempts: &attempts
            ) {
                if logDiagnostics {
                    DiagnosticLog.log("[Focus] Resolved focused element via system focused application for \(appName) (\(bundleIdentifier)).")
                }
                return FocusResolution(element: element, path: "systemFocusedApplication")
            }
        } else {
            attempts.append("systemFocusedApplication=\(focusedAppError.rawValue)")
        }

        if let element = focusedElement(
            from: system,
            label: "systemWide",
            attempts: &attempts
        ) {
            if logDiagnostics {
                DiagnosticLog.log("[Focus] Resolved focused element via system-wide lookup for \(appName) (\(bundleIdentifier)).")
            }
            return FocusResolution(element: element, path: "systemWide")
        }

        if logDiagnostics {
            DiagnosticLog.log(
                "[Focus] Failed to resolve focused UI element for \(appName) (\(bundleIdentifier)). attempts=\(attempts.joined(separator: " | "))"
            )
        }
        return nil
    }

    private static func focusedElement(
        from source: AXUIElement,
        label: String,
        attempts: inout [String]
    ) -> AXUIElement? {
        var focusedRef: CFTypeRef?
        let error = copyAttributeValueWithRetries(
            from: source,
            attribute: kAXFocusedUIElementAttribute as CFString,
            value: &focusedRef
        )
        guard error == .success, let focusedRef else {
            attempts.append("\(label)=\(error.rawValue)")
            return nil
        }
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            attempts.append("\(label)=unexpected-type")
            return nil
        }
        return unsafeBitCast(focusedRef, to: AXUIElement.self)
    }

    @discardableResult
    private static func copyAttributeValueWithRetries(
        from source: AXUIElement,
        attribute: CFString,
        value: inout CFTypeRef?
    ) -> AXError {
        let retryDelays: [useconds_t] = [0, 20_000, 80_000]
        var lastError: AXError = .failure

        for delay in retryDelays {
            if delay > 0 {
                usleep(delay)
            }

            value = nil
            lastError = AXUIElementCopyAttributeValue(source, attribute, &value)
            if lastError == .success || lastError != .cannotComplete {
                return lastError
            }
        }

        return lastError
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

    private static func attributeValue(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private static func selectionElements(startingAt element: AXUIElement) -> [AXUIElement] {
        var elements: [AXUIElement] = []
        var current: AXUIElement? = element

        for _ in 0..<8 {
            guard let currentElement = current else { break }
            elements.append(currentElement)
            current = uiElementAttribute(kAXParentAttribute as CFString, of: currentElement)
        }
        return elements
    }

    private static func uiElementAttribute(_ name: CFString, of element: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func text(for markerRange: CFTypeRef, in element: AXUIElement) -> String? {
        let markerAttributes: [CFString] = [
            "AXStringForTextMarkerRange" as CFString,
            "AXAttributedStringForTextMarkerRange" as CFString,
        ]
        for attribute in markerAttributes {
            if let text = parameterizedText(attribute, parameter: markerRange, in: element) {
                return text
            }
        }
        return nil
    }

    private static func text(for range: CFRange, in element: AXUIElement) -> String? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        return parameterizedText(
            "AXStringForRange" as CFString,
            parameter: rangeValue,
            in: element
        )
    }

    private static func parameterizedText(
        _ attribute: CFString,
        parameter: CFTypeRef,
        in element: AXUIElement
    ) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute, parameter, &result) == .success,
              let result else { return nil }
        if let string = result as? String {
            return string
        }
        return (result as? NSAttributedString)?.string
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

    private static func caretFrame(of element: AXUIElement) -> NSRect? {
        guard var range = selectedTextRangeAttribute(of: element) else { return nil }
        range.location += range.length
        range.length = 0
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXBoundsForRange" as CFString,
            rangeValue,
            &boundsRef
        ) == .success,
              let boundsRef,
              CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }

        var axRect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &axRect) else { return nil }
        return cocoaFrame(from: axRect)
    }

    private static func frameAttribute(of element: AXUIElement) -> NSRect? {
        var frameRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameRef) == .success,
              let frameRef,
              CFGetTypeID(frameRef) == AXValueGetTypeID() else { return nil }

        var axRect = CGRect.zero
        guard AXValueGetValue(frameRef as! AXValue, .cgRect, &axRect) else { return nil }

        return cocoaFrame(from: axRect)
    }

    private static func cocoaFrame(from axRect: CGRect) -> NSRect {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(
            x: axRect.origin.x,
            y: screenHeight - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height
        )
    }
}
