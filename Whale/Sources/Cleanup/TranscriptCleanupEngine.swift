import Foundation

/// One pass of a local model over one chunk of transcript.
///
/// Narrow on purpose: chunking, guardrails and settings all live above this line, so the
/// stage can be tested against a stub and the MLX runtime never has to be loaded to
/// answer a question about behaviour.
protocol TranscriptCleanupEngine: Sendable {
    /// Rewrites one dictation-length transcript. Returns whatever the model produced,
    /// including an empty string — deciding whether an empty result is believable is
    /// `TranscriptCleanupGuard`'s job, not the engine's.
    func clean(_ transcript: String, options: TranscriptCleanupOptions) async throws -> String

    /// Loads the model ahead of the first request, so a dictation does not pay for it.
    /// Failure is deliberately swallowed: warming is an optimization, and the real
    /// attempt reports properly.
    func warm() async

    /// Drops the loaded model. Called on memory pressure and after an idle spell.
    func unload() async
}

extension TranscriptCleanupEngine {
    func warm() async {}
    func unload() async {}
}

enum TranscriptCleanupError: LocalizedError {
    case modelNotInstalled
    case timedOut
    case rejected

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "S1-mini is not downloaded. Open Settings › Models and download it."
        case .timedOut:
            return "Cleanup took too long and was abandoned; the raw transcript was kept."
        case .rejected:
            return "Cleanup returned an implausible rewrite; the raw transcript was kept."
        }
    }
}

/// The line between "a language model improved this transcript" and "a language model ate
/// this transcript".
///
/// Everything else in the pipeline is deterministic. This stage is not, and its failure
/// mode is not a mangled word but a lost dictation, so a rewrite has to look like a
/// rewrite of *this* input before it is allowed to replace it.
enum TranscriptCleanupGuard {

    /// Below this the ratio tests are noise: a three-word utterance can legitimately
    /// clean up to one word.
    static let minimumWordsForRatioCheck = 12

    /// The floor was picked against the model card's own worked example — 17 words of
    /// filler and self-correction cleaning down to 8, or 47% — with room underneath for
    /// a heavier-filler dictation. Anything below this is not filler removal, it is
    /// truncation.
    static let minimumRetainedFraction = 0.35

    /// A rewrite that is much longer than its input is the model having started to
    /// improvise rather than normalize.
    static let maximumGrowthFactor = 2.5

    /// Filler-only input legitimately cleans to nothing, and the model card asks for that
    /// to be treated as a valid result. But "nothing" is only believable when there was
    /// almost nothing there: an empty rewrite of a real sentence is a bug, and accepting
    /// it silently discards a dictation.
    static let maximumWordsForEmptyResult = 3

    /// Returns the cleaned text when it is a plausible rewrite of `raw`, or `nil` when the
    /// raw transcript should be kept instead.
    static func accept(cleaned: String, raw: String) -> String? {
        let cleaned = sanitize(cleaned)
        let rawWords = wordCount(raw)
        let cleanedWords = wordCount(cleaned)

        if cleanedWords == 0 {
            return rawWords <= maximumWordsForEmptyResult ? cleaned : nil
        }

        guard rawWords >= minimumWordsForRatioCheck else { return cleaned }

        let ratio = Double(cleanedWords) / Double(rawWords)
        guard ratio >= minimumRetainedFraction, ratio <= maximumGrowthFactor else {
            return nil
        }

        return cleaned
    }

    /// Strips the chat-format scaffolding and the control line in the rare pass where the
    /// model echoes them back, so a single stray turn marker does not reach the user's
    /// document.
    static func sanitize(_ text: String) -> String {
        var result = text

        for marker in ["<|im_end|>", "<|im_start|>", "<|endoftext|>", "<think>", "</think>"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }

        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("[Styling:") {
            result = lines.dropFirst().joined(separator: "\n")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
