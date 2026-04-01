import XCTest
@testable import Whale

final class PromptBuilderTests: XCTestCase {
    func testPromptDoesNotIncludeAppContextWhenPresent() {
        let prompt = PromptBuilder.buildCleanupPrompt(
            transcript: "hello world",
            focusedAppContext: FocusedAppContext(appName: "Notes", bundleIdentifier: "com.apple.Notes"),
            cleanupLevel: .medium
        )

        XCTAssertFalse(prompt.contains("App name:"))
        XCTAssertFalse(prompt.contains("Bundle ID:"))
        XCTAssertFalse(prompt.contains("Cleanup level:"))
    }

    func testPromptOmitsContextWhenNil() {
        let prompt = PromptBuilder.buildCleanupPrompt(
            transcript: "hello world",
            focusedAppContext: nil,
            cleanupLevel: .light
        )

        XCTAssertFalse(prompt.contains("App name:"))
        XCTAssertFalse(prompt.contains("Bundle ID:"))
    }

    func testPromptRequiresOutputOnlyResponse() {
        let prompt = PromptBuilder.buildCleanupPrompt(
            transcript: "hello world",
            focusedAppContext: nil,
            cleanupLevel: .light
        )

        XCTAssertTrue(prompt.contains("Return only the cleaned text. No quotes, labels, or explanations."))
        XCTAssertTrue(prompt.contains("Text to clean:\nhello world"))
        XCTAssertFalse(prompt.contains("Preserve natural Hindi-English code-switching."))
    }
}
