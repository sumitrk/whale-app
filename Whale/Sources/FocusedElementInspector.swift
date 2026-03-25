import AppKit
import ApplicationServices

struct FocusedElementSnapshot {
    let appName: String?
    let bundleIdentifier: String?
    let role: String?
    let subrole: String?
    let isEditable: Bool
    let supportsSelectedTextRange: Bool
    let frame: NSRect?

    private static let knownTextRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
    ]

    var isWritableTextTarget: Bool {
        if let role, Self.knownTextRoles.contains(role) {
            return true
        }
        return isEditable || supportsSelectedTextRange
    }
}

enum FocusedElementInspector {
    static func snapshot() -> FocusedElementSnapshot? {
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
        let isEditable = boolAttribute("AXEditable" as CFString, of: element)
        let supportsSelectedTextRange = names.contains(kAXSelectedTextRangeAttribute as String)
        let frame = frameAttribute(of: element)

        return FocusedElementSnapshot(
            appName: NSWorkspace.shared.frontmostApplication?.localizedName,
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            role: role,
            subrole: subrole,
            isEditable: isEditable,
            supportsSelectedTextRange: supportsSelectedTextRange,
            frame: frame
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

    private static func frameAttribute(of element: AXUIElement) -> NSRect? {
        var frameRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameRef) == .success,
              let frameRef else { return nil }

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
