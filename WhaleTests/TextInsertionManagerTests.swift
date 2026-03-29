import AppKit
import XCTest
@testable import Whale

final class TextInsertionManagerTests: XCTestCase {

    // MARK: - Strategy selection

    func testSettableNativeTextFieldPrefersDirectAX() {
        let snapshot = makeSnapshot(
            appName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            role: "AXTextArea",
            isEditable: true,
            supportsSelectedTextRange: true,
            supportsAXValue: true,
            canReadAXValueAsString: true,
            isAXValueSettable: true,
            canReadSelectedTextRange: true,
            isSelectedTextRangeSettable: true
        )

        XCTAssertEqual(
            TextInsertionManager.insertionStrategy(
                for: snapshot,
                isAccessibilityTrusted: true
            ),
            .directAX
        )
    }

    func testChromiumTextAreaPrefersSimulatedPasteEvenWhenSettable() {
        let snapshot = makeSnapshot(
            appName: "Codex",
            bundleIdentifier: "com.openai.codex",
            role: "AXTextArea",
            isEditable: false,
            supportsSelectedTextRange: true,
            supportsAXValue: true,
            canReadAXValueAsString: true,
            isAXValueSettable: true,
            canReadSelectedTextRange: true,
            isSelectedTextRangeSettable: true,
            attributeNames: [
                "AXValue",
                "AXSelectedTextRange",
                "ChromeAXNodeId",
                "AXDOMIdentifier",
                "AXSelectedTextMarkerRange",
            ]
        )

        XCTAssertEqual(
            TextInsertionManager.insertionStrategy(
                for: snapshot,
                isAccessibilityTrusted: true
            ),
            .simulatedPaste
        )
    }

    func testWritableTargetWithoutSettableValueFallsBackToSimulatedPaste() {
        let snapshot = makeSnapshot(
            appName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            role: "AXTextArea",
            isEditable: true,
            supportsSelectedTextRange: true,
            supportsAXValue: true,
            canReadAXValueAsString: true,
            isAXValueSettable: false,
            canReadSelectedTextRange: true,
            isSelectedTextRangeSettable: true
        )

        XCTAssertEqual(
            TextInsertionManager.insertionStrategy(
                for: snapshot,
                isAccessibilityTrusted: true
            ),
            .simulatedPaste
        )
    }

    func testWritableTargetWithoutReadableRangeFallsBackToSimulatedPaste() {
        let snapshot = makeSnapshot(
            appName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            role: "AXTextArea",
            isEditable: true,
            supportsSelectedTextRange: true,
            supportsAXValue: true,
            canReadAXValueAsString: true,
            isAXValueSettable: true,
            canReadSelectedTextRange: false,
            isSelectedTextRangeSettable: true
        )

        XCTAssertEqual(
            TextInsertionManager.insertionStrategy(
                for: snapshot,
                isAccessibilityTrusted: true
            ),
            .simulatedPaste
        )
    }

    func testChromiumGroupFallsBackToSimulatedPasteWithoutSafeAXCapability() {
        let snapshot = makeSnapshot(
            appName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            role: "AXGroup",
            isEditable: false,
            supportsSelectedTextRange: false,
            supportsAXValue: true,
            canReadAXValueAsString: false,
            isAXValueSettable: false,
            canReadSelectedTextRange: false,
            isSelectedTextRangeSettable: false
        )

        XCTAssertEqual(
            TextInsertionManager.insertionStrategy(
                for: snapshot,
                isAccessibilityTrusted: true
            ),
            .simulatedPaste
        )
    }

    func testNilSnapshotWithoutAccessibilityUsesCopyOnly() {
        XCTAssertEqual(
            TextInsertionManager.insertionStrategy(
                for: nil,
                isAccessibilityTrusted: false
            ),
            .copyOnly(.accessibilityMissing)
        )
    }

    func testNonWritableTargetUsesCopyOnly() {
        let snapshot = makeSnapshot(
            appName: "Finder",
            bundleIdentifier: "com.apple.finder",
            role: "AXButton",
            isEditable: false,
            supportsSelectedTextRange: false,
            supportsAXValue: false
        )

        XCTAssertEqual(
            TextInsertionManager.insertionStrategy(
                for: snapshot,
                isAccessibilityTrusted: true
            ),
            .copyOnly(.manualPasteOnly)
        )
    }

    // MARK: - Replacement logic

    func testInsertAtCaret() {
        let result = TextInsertionManager.replacingSelectedRange(
            in: "Hello world",
            selectedRange: CFRange(location: 5, length: 0),
            with: ", brave new"
        )

        XCTAssertEqual(result?.updatedValue, "Hello, brave new world")
        XCTAssertEqual(result?.resultingSelectedRange, NSRange(location: 16, length: 0))
    }

    func testReplaceSelectedSubstring() {
        let result = TextInsertionManager.replacingSelectedRange(
            in: "Hello world",
            selectedRange: CFRange(location: 6, length: 5),
            with: "Whale"
        )

        XCTAssertEqual(result?.updatedValue, "Hello Whale")
        XCTAssertEqual(result?.resultingSelectedRange, NSRange(location: 11, length: 0))
    }

    func testInsertAtBeginningAndEnd() {
        let beginning = TextInsertionManager.replacingSelectedRange(
            in: "world",
            selectedRange: CFRange(location: 0, length: 0),
            with: "Hello "
        )
        let end = TextInsertionManager.replacingSelectedRange(
            in: "Hello",
            selectedRange: CFRange(location: 5, length: 0),
            with: " world"
        )

        XCTAssertEqual(beginning?.updatedValue, "Hello world")
        XCTAssertEqual(beginning?.resultingSelectedRange, NSRange(location: 6, length: 0))
        XCTAssertEqual(end?.updatedValue, "Hello world")
        XCTAssertEqual(end?.resultingSelectedRange, NSRange(location: 11, length: 0))
    }

    func testUnicodeReplacementUsesUTF16Ranges() {
        let original = "Hi 👋 friend"
        let nsOriginal = original as NSString
        let emojiRange = nsOriginal.range(of: "👋")
        let result = TextInsertionManager.replacingSelectedRange(
            in: original,
            selectedRange: CFRange(location: emojiRange.location, length: emojiRange.length),
            with: "🚀"
        )

        XCTAssertEqual(result?.updatedValue, "Hi 🚀 friend")
        XCTAssertEqual(
            result?.resultingSelectedRange,
            NSRange(location: emojiRange.location + ("🚀" as NSString).length, length: 0)
        )
    }

    func testOutOfBoundsSelectedRangeFails() {
        let result = TextInsertionManager.replacingSelectedRange(
            in: "Hello",
            selectedRange: CFRange(location: 99, length: 0),
            with: " world"
        )

        XCTAssertNil(result)
    }

    // MARK: - Pasteboard helpers

    func testPasteboardSnapshotRoundTripsStringContent() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)

        let snapshot = TextInsertionManager.PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        snapshot.restore(to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testClipboardRestoreSkippedWhenChangeCountChanged() {
        XCTAssertFalse(
            TextInsertionManager.shouldRestoreClipboard(
                currentChangeCount: 8,
                expectedTemporaryChangeCount: 7
            )
        )
        XCTAssertTrue(
            TextInsertionManager.shouldRestoreClipboard(
                currentChangeCount: 7,
                expectedTemporaryChangeCount: 7
            )
        )
    }

    private func makeSnapshot(
        appName: String,
        bundleIdentifier: String,
        role: String?,
        isEditable: Bool,
        supportsSelectedTextRange: Bool,
        supportsAXValue: Bool,
        canReadAXValueAsString: Bool = false,
        isAXValueSettable: Bool = false,
        canReadSelectedTextRange: Bool = false,
        isSelectedTextRangeSettable: Bool = false,
        attributeNames: [String] = []
    ) -> FocusedElementSnapshot {
        FocusedElementSnapshot(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            role: role,
            subrole: nil,
            roleDescription: role == "AXButton" ? "button" : nil,
            placeholderValue: nil,
            numberOfCharacters: nil,
            isEditable: isEditable,
            supportsSelectedTextRange: supportsSelectedTextRange,
            supportsAXValue: supportsAXValue,
            canReadAXValueAsString: canReadAXValueAsString,
            isAXValueSettable: isAXValueSettable,
            canReadSelectedTextRange: canReadSelectedTextRange,
            isSelectedTextRangeSettable: isSelectedTextRangeSettable,
            frame: nil,
            attributeNames: attributeNames
        )
    }

    func testPlaceholderOnlyAXValueNormalizesToEmptyText() {
        let normalized = TextInsertionManager.normalizedEditingState(
            currentValue: "Ask for follow-up changes",
            selectedRange: CFRange(location: 27, length: 0),
            placeholderValue: "Ask for follow-up changes",
            numberOfCharacters: 0
        )

        XCTAssertEqual(normalized.currentValue, "")
        XCTAssertEqual(normalized.selectedRange.location, 0)
        XCTAssertEqual(normalized.selectedRange.length, 0)
    }

    func testNonPlaceholderValueStaysUntouched() {
        let normalized = TextInsertionManager.normalizedEditingState(
            currentValue: "Hello",
            selectedRange: CFRange(location: 5, length: 0),
            placeholderValue: "Ask for follow-up changes",
            numberOfCharacters: 5
        )

        XCTAssertEqual(normalized.currentValue, "Hello")
        XCTAssertEqual(normalized.selectedRange.location, 5)
        XCTAssertEqual(normalized.selectedRange.length, 0)
    }

    func testZeroCharacterCountTreatsNonEmptyValueAsPlaceholder() {
        let normalized = TextInsertionManager.normalizedEditingState(
            currentValue: "Ask for follow-up changes",
            selectedRange: CFRange(location: 27, length: 0),
            placeholderValue: nil,
            numberOfCharacters: 0
        )

        XCTAssertEqual(normalized.currentValue, "")
        XCTAssertEqual(normalized.selectedRange.location, 0)
        XCTAssertEqual(normalized.selectedRange.length, 0)
    }

    // MARK: - Character probe (AXStringForRange) phantom placeholder detection

    func testPhantomPlaceholderDetectedByEmptyProbe() {
        let normalized = TextInsertionManager.normalizedEditingState(
            currentValue: "Ask for follow-up changes",
            selectedRange: CFRange(location: 0, length: 0),
            placeholderValue: nil,
            numberOfCharacters: nil,
            characterProbe: .empty
        )

        XCTAssertEqual(normalized.currentValue, "")
        XCTAssertEqual(normalized.selectedRange.location, 0)
        XCTAssertEqual(normalized.selectedRange.length, 0)
    }

    func testRealContentConfirmedByProbeStaysUntouched() {
        let normalized = TextInsertionManager.normalizedEditingState(
            currentValue: "Hello world",
            selectedRange: CFRange(location: 11, length: 0),
            placeholderValue: nil,
            numberOfCharacters: nil,
            characterProbe: .realContent("H")
        )

        XCTAssertEqual(normalized.currentValue, "Hello world")
        XCTAssertEqual(normalized.selectedRange.location, 11)
        XCTAssertEqual(normalized.selectedRange.length, 0)
    }

    func testUnsupportedProbeFallsBackToPlaceholderMatch() {
        let normalized = TextInsertionManager.normalizedEditingState(
            currentValue: "Type here...",
            selectedRange: CFRange(location: 0, length: 0),
            placeholderValue: "Type here...",
            numberOfCharacters: nil,
            characterProbe: .unsupported
        )

        XCTAssertEqual(normalized.currentValue, "")
        XCTAssertEqual(normalized.selectedRange.location, 0)
        XCTAssertEqual(normalized.selectedRange.length, 0)
    }

    func testUnsupportedProbeWithNoMetadataPassesValueThrough() {
        let normalized = TextInsertionManager.normalizedEditingState(
            currentValue: "Some text",
            selectedRange: CFRange(location: 9, length: 0),
            placeholderValue: nil,
            numberOfCharacters: nil,
            characterProbe: .unsupported
        )

        XCTAssertEqual(normalized.currentValue, "Some text")
        XCTAssertEqual(normalized.selectedRange.location, 9)
        XCTAssertEqual(normalized.selectedRange.length, 0)
    }
}
