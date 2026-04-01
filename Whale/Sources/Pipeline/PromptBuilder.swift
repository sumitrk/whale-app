import Foundation

enum PromptBuilder {
    static func buildCleanupInstructions(
        focusedAppContext: FocusedAppContext?,
        cleanupLevel: CleanupLevel
    ) -> String {
        _ = focusedAppContext

        let levelInstruction = switch cleanupLevel {
        case .light:
            "Apply only minimal cleanup."
        case .medium:
            "Apply concise cleanup for direct insertion into another app."
        }

        return """
        Clean up dictated text for insertion into another app.
        \(levelInstruction)
        Fix grammar, punctuation, and capitalization.
        Preserve the original meaning and tone.
        Keep only the final intended wording when the speaker self-corrects.
        Do not add facts or extra content.
        Return only the cleaned text.
        """
    }

    static func buildCleanupUserPrompt(transcript: String) -> String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func maxTokens(
        for transcript: String,
        cleanupLevel: CleanupLevel,
        outputMode: OutputMode
    ) -> Int {
        let wordCount = transcript.split(whereSeparator: \.isWhitespace).count
        let base = max(16, min(wordCount + 12, outputMode == .paste ? 64 : 160))

        switch cleanupLevel {
        case .light:
            return min(base, outputMode == .paste ? 48 : 96)
        case .medium:
            return base
        }
    }

    static func buildCleanupPrompt(
        transcript: String,
        focusedAppContext: FocusedAppContext?,
        cleanupLevel: CleanupLevel
    ) -> String {
        let instructions = buildCleanupInstructions(
            focusedAppContext: focusedAppContext,
            cleanupLevel: cleanupLevel
        )
        let userPrompt = buildCleanupUserPrompt(transcript: transcript)

        return """
        \(instructions)
        Return only the cleaned text. No quotes, labels, or explanations.
        Text to clean:
        \(userPrompt)
        """
    }
}
