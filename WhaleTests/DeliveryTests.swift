import XCTest
@testable import Whale

/// Delivery end to end, against a fake system: which strategy runs, what it reports, and what
/// happens to the user's clipboard.
@MainActor
final class DeliveryTests: XCTestCase {
    private var system: FakeDeliverySystem!
    private var delivery: Delivery!

    override func setUp() async throws {
        system = FakeDeliverySystem()
        delivery = Delivery(system: system, pasteDelay: .zero, restoreDelay: .zero)
    }

    func testASettableTextFieldIsWrittenDirectly() {
        system.target = Self.target(directInsert: true)

        XCTAssertEqual(delivery.deliver("Hello"), .inserted)
        XCTAssertEqual(system.inserted, ["Hello"])
        XCTAssertEqual(system.clipboard, "original", "a direct insert leaves the clipboard alone")
        XCTAssertEqual(system.pastes, 0)
    }

    func testAFailedDirectInsertFallsBackToPastingAndRestoresTheClipboard() async {
        system.target = Self.target(directInsert: true)
        system.insertError = TestError.rejected

        XCTAssertEqual(delivery.deliver("Hello"), .pasted)
        XCTAssertEqual(system.clipboard, "Hello", "the text is on the clipboard for ⌘V")
        await delivery.pendingPaste?.value

        XCTAssertEqual(system.pastes, 1)
        XCTAssertEqual(system.clipboard, "original")
    }

    func testAWritableFieldWithoutDirectAccessIsPasted() async {
        system.target = Self.target(directInsert: false)

        XCTAssertEqual(delivery.deliver("Hello"), .pasted)
        await delivery.pendingPaste?.value

        XCTAssertTrue(system.inserted.isEmpty)
        XCTAssertEqual(system.pastes, 1)
        XCTAssertEqual(system.clipboard, "original")
    }

    func testTheClipboardIsLeftAloneIfSomethingElseWroteToIt() async {
        system.target = Self.target(directInsert: false)
        system.onPaste = { $0.copy("copied by the user") }

        _ = delivery.deliver("Hello")
        await delivery.pendingPaste?.value

        XCTAssertEqual(system.clipboard, "copied by the user")
    }

    func testNoFocusedFieldPastesWhenEventsAreAllowed() async {
        system.target = nil

        XCTAssertEqual(delivery.deliver("Hello"), .pasted)
    }

    func testANonEditableTargetLeavesTheTextOnTheClipboard() {
        system.target = Self.target(directInsert: false, editable: false)

        XCTAssertEqual(delivery.deliver("Hello"), .copied(.manualPasteOnly))
        XCTAssertEqual(system.clipboard, "Hello")
        XCTAssertEqual(system.pastes, 0)
    }

    func testWithoutAnyPermissionTheTextIsCopiedAndTheHintSaysWhy() {
        system.isAccessibilityTrusted = false
        system.canPostEvents = false
        system.target = Self.target(directInsert: true)

        XCTAssertEqual(delivery.deliver("Hello"), .copied(.accessibilityMissing))
        XCTAssertEqual(system.clipboard, "Hello")
    }

    // MARK: - Helpers

    private enum TestError: Error { case rejected }

    private static func target(directInsert: Bool, editable: Bool = true) -> DeliveryTarget {
        DeliveryTarget(
            snapshot: FocusedElementSnapshot(
                appName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                role: editable ? "AXTextArea" : "AXButton",
                subrole: nil,
                roleDescription: editable ? nil : "button",
                placeholderValue: nil,
                numberOfCharacters: nil,
                isEditable: editable,
                supportsSelectedTextRange: editable,
                supportsAXValue: editable,
                canReadAXValueAsString: directInsert,
                isAXValueSettable: directInsert,
                canReadSelectedTextRange: directInsert,
                isSelectedTextRangeSettable: directInsert,
                frame: nil,
                attributeNames: []
            ),
            context: nil
        )
    }
}

@MainActor
private final class FakeDeliverySystem: DeliverySystem {
    var isAccessibilityTrusted = true
    var canPostEvents = true
    var target: DeliveryTarget?
    var insertError: Error?
    var inserted: [String] = []
    var clipboard = "original"
    var pasteboardChangeCount = 0
    var pastes = 0
    var onPaste: (FakeDeliverySystem) -> Void = { _ in }

    func focusedTarget() -> DeliveryTarget? { target }

    func insert(_ text: String, into target: DeliveryTarget) throws {
        if let insertError { throw insertError }
        inserted.append(text)
    }

    func savePasteboard() -> TextInsertionManager.PasteboardSnapshot {
        TextInsertionManager.PasteboardSnapshot(items: [["public.utf8-plain-text": Data(clipboard.utf8)]])
    }

    func restorePasteboard(_ snapshot: TextInsertionManager.PasteboardSnapshot) {
        clipboard = snapshot.items.first.flatMap { $0["public.utf8-plain-text"] }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        pasteboardChangeCount += 1
    }

    func copy(_ text: String) {
        clipboard = text
        pasteboardChangeCount += 1
    }

    func pressPaste() {
        pastes += 1
        onPaste(self)
    }
}
