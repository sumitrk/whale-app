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

    func testPromptUsesConciseCleanupInstructions() {
        let prompt = PromptBuilder.buildCleanupPrompt(
            transcript: "there are errors when i'm encountering in the log not sure how important they are",
            focusedAppContext: nil,
            cleanupLevel: .medium
        )

        XCTAssertTrue(prompt.contains("Apply concise cleanup for direct insertion into another app."))
        XCTAssertTrue(prompt.contains("Keep only the final intended wording when the speaker self-corrects."))
        XCTAssertFalse(prompt.contains("Do not omit, compress, summarize, or paraphrase any spoken content."))
    }

    func testPromptUsesCustomInstructionsWhenProvided() {
        let prompt = PromptBuilder.buildCleanupPrompt(
            transcript: "hello world",
            focusedAppContext: nil,
            cleanupLevel: .medium,
            customInstructions: "Fix grammar only.\nReturn only the cleaned text."
        )

        XCTAssertTrue(prompt.contains("Fix grammar only."))
        XCTAssertFalse(prompt.contains("Apply concise cleanup for direct insertion into another app."))
    }
}
