import Foundation

/// Totals across every finished dictation, for the numbers at the top of History.
struct DictationStats: Equatable, Sendable {
    /// A typical typing speed, what speaking is compared against.
    static let typingWordsPerMinute: Double = 40

    var dictationCount = 0
    var words = 0
    var speakingSeconds: Double = 0

    var wordsPerMinute: Int? {
        guard speakingSeconds >= 1, words > 0 else { return nil }
        return Int((Double(words) / (speakingSeconds / 60)).rounded())
    }

    /// How much longer typing the same words would have taken.
    var secondsSaved: Double {
        max(0, Double(words) / Self.typingWordsPerMinute * 60 - speakingSeconds)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
