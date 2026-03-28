import XCTest
@testable import Whale

final class TextInsertionManagerTests: XCTestCase {

    // MARK: - Auto-paste decisions

    func testNativeTextFieldTriggersAutoPaste() {
        let snapshot = FocusedElementSnapshot(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            role: "AXTextArea",
            subrole: nil,
            roleDescription: "text area",
            isEditable: true,
            supportsSelectedTextRange: true,
            supportsAXValue: true,
            frame: nil,
            attributeNames: ["AXValue", "AXSelectedTextRange"]
        )

        XCTAssertEqual(TextInsertionManager.pasteDecision(for: snapshot), .autoPaste)
    }

    func testTextFieldRoleTriggersAutoPaste() {
        let snapshot = FocusedElementSnapshot(
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            role: "AXTextField",
            subrole: nil,
            roleDescription: "text field",
            isEditable: true,
            supportsSelectedTextRange: true,
            supportsAXValue: true,
            frame: nil,
            attributeNames: ["AXValue"]
        )

        XCTAssertEqual(TextInsertionManager.pasteDecision(for: snapshot), .autoPaste)
    }

    func testSearchFieldTriggersAutoPaste() {
        let snapshot = FocusedElementSnapshot(
            appName: "Finder",
            bundleIdentifier: "com.apple.finder",
            role: "AXSearchField",
            subrole: nil,
            roleDescription: "search text field",
            isEditable: true,
            supportsSelectedTextRange: true,
            supportsAXValue: true,
            frame: nil,
            attributeNames: ["AXValue"]
        )

        XCTAssertEqual(TextInsertionManager.pasteDecision(for: snapshot), .autoPaste)
    }

    func testEditableElementWithNoKnownRoleTriggersAutoPaste() {
        let snapshot = FocusedElementSnapshot(
            appName: "Some App",
            bundleIdentifier: "com.example.app",
            role: "AXUnknown",
            subrole: nil,
            roleDescription: nil,
            isEditable: true,
            supportsSelectedTextRange: false,
            supportsAXValue: false,
            frame: nil,
            attributeNames: []
        )

        XCTAssertEqual(TextInsertionManager.pasteDecision(for: snapshot), .autoPaste)
    }

    func testSelectedTextRangeSupportTriggersAutoPaste() {
        let snapshot = FocusedElementSnapshot(
            appName: "VS Code",
            bundleIdentifier: "com.microsoft.VSCode",
            role: "AXGroup",
            subrole: nil,
            roleDescription: nil,
            isEditable: false,
            supportsSelectedTextRange: true,
            supportsAXValue: false,
            frame: nil,
            attributeNames: ["AXSelectedTextRange"]
        )

        XCTAssertEqual(TextInsertionManager.pasteDecision(for: snapshot), .autoPaste)
    }

    // MARK: - Clipboard-only decisions

    func testNilSnapshotTriggersClipboardOnly() {
        let decision = TextInsertionManager.pasteDecision(for: nil)

        if case .clipboardOnly = decision {
            // expected
        } else {
            XCTFail("Expected clipboardOnly, got \(decision)")
        }
    }

    func testNonEditableNonTextRoleTriggersClipboardOnly() {
        let snapshot = FocusedElementSnapshot(
            appName: "Finder",
            bundleIdentifier: "com.apple.finder",
            role: "AXButton",
            subrole: nil,
            roleDescription: "button",
            isEditable: false,
            supportsSelectedTextRange: false,
            supportsAXValue: false,
            frame: nil,
            attributeNames: []
        )

        if case .clipboardOnly = TextInsertionManager.pasteDecision(for: snapshot) {
            // expected
        } else {
            XCTFail("Expected clipboardOnly for a button element")
        }
    }

    func testStaticTextTriggersClipboardOnly() {
        let snapshot = FocusedElementSnapshot(
            appName: "Finder",
            bundleIdentifier: "com.apple.finder",
            role: "AXStaticText",
            subrole: nil,
            roleDescription: "text",
            isEditable: false,
            supportsSelectedTextRange: false,
            supportsAXValue: false,
            frame: nil,
            attributeNames: []
        )

        if case .clipboardOnly = TextInsertionManager.pasteDecision(for: snapshot) {
            // expected
        } else {
            XCTFail("Expected clipboardOnly for static text")
        }
    }

    // MARK: - Chromium browser heuristics

    func testChromiumGroupWithAXValueTriggersAutoPaste() {
        let snapshot = FocusedElementSnapshot(
            appName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            role: "AXGroup",
            subrole: nil,
            roleDescription: nil,
            isEditable: false,
            supportsSelectedTextRange: false,
            supportsAXValue: true,
            frame: nil,
            attributeNames: ["AXValue"]
        )

        XCTAssertEqual(TextInsertionManager.pasteDecision(for: snapshot), .autoPaste)
    }

    func testChromiumGroupWithoutIndicatorsStillTriggersAutoPaste() {
        let snapshot = FocusedElementSnapshot(
            appName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            role: "AXGroup",
            subrole: nil,
            roleDescription: nil,
            isEditable: false,
            supportsSelectedTextRange: false,
            supportsAXValue: false,
            frame: nil,
            attributeNames: []
        )

        XCTAssertEqual(TextInsertionManager.pasteDecision(for: snapshot), .autoPaste)
    }

    func testArcBrowserGroupTriggersAutoPaste() {
        let snapshot = FocusedElementSnapshot(
            appName: "Arc",
            bundleIdentifier: "com.arc.Arc",
            role: "AXGroup",
            subrole: nil,
            roleDescription: nil,
            isEditable: false,
            supportsSelectedTextRange: false,
            supportsAXValue: false,
            frame: nil,
            attributeNames: []
        )

        XCTAssertEqual(TextInsertionManager.pasteDecision(for: snapshot), .autoPaste)
    }
}
