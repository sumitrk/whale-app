import CNemoTextProcessing
import Foundation

/// Inverse text normalization: rewrites the spoken forms an ASR model produces
/// into the written forms a reader expects.
///
/// - "twenty one dollars" → "$21"
/// - "january fifth twenty twenty five" → "January 5, 2025"
/// - "two thirty pm" → "2:30 p.m."
///
/// A thin Swift surface over the C FFI of `text-processing-rs`. Only the
/// spoken → written direction is exposed; the written → spoken half of the
/// library exists for text-to-speech, which Whale does not do.
public enum SpokenFormNormalizer {

    /// Rewrites every spoken-form span in `text`, leaving the rest untouched.
    ///
    /// - Parameters:
    ///   - text: A transcript, or any sentence containing spoken forms.
    ///   - concatCompoundNumbers: When true, consecutive numbers below one
    ///     hundred concatenate instead of adding ("thirty five sixty two" →
    ///     "3562"), which suits call signs and flight numbers rather than prose.
    ///   - maxSpanTokens: Longest run of words considered one span. Zero uses
    ///     the engine default of 16.
    ///   - keepBareSecond: When true, a lone "second" stays a word, so "give me
    ///     a second" survives. Compound ordinals ("twenty second" → "22nd")
    ///     still convert.
    /// - Returns: The rewritten text, or `text` unchanged when nothing applies.
    public static func writtenForm(
        _ text: String,
        concatCompoundNumbers: Bool = false,
        maxSpanTokens: UInt32 = 0,
        keepBareSecond: Bool = true
    ) -> String {
        func rewrite(_ input: String) -> String {
            input.withCString { pointer in
                guard let result = nemo_normalize_sentence_with_options(
                    pointer,
                    concatCompoundNumbers ? 1 : 0,
                    maxSpanTokens,
                    keepBareSecond ? 1 : 0
                ) else {
                    return input
                }
                defer { nemo_free_string(result) }
                return String(cString: result)
            }
        }

        let direct = rewrite(text)
        if direct != text { return direct }

        // The engine matches "twenty one" but not "twenty-one", and a hyphen is
        // exactly what Parakeet writes when it falls back to spoken form. Retry
        // with those hyphens opened up, and only keep that attempt if it earned
        // the change — otherwise a sentence would silently lose its hyphens.
        let opened = openingHyphenatedNumbers(in: text)
        guard opened != text else { return text }

        let retried = rewrite(opened)
        return retried == opened ? text : retried
    }

    /// Replaces the hyphen in a spelled compound number ("twenty-one",
    /// "thirty-second") with a space. Deliberately narrow: it matches only a
    /// tens word joined to a unit or unit-ordinal, so "state-of-the-art" and
    /// every other hyphenated word is left alone. A number inside a longer
    /// hyphen chain is skipped too — opening "twenty-one-gun" leaves the engine
    /// a dangling "one-gun" and it mangles the phrase.
    private static func openingHyphenatedNumbers(in text: String) -> String {
        guard text.contains("-") else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return compoundNumber.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: "$1 $2"
        )
    }

    private static let compoundNumber: NSRegularExpression = {
        let tens = "twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
        let units = "one|two|three|four|five|six|seven|eight|nine"
        let ordinals = "first|second|third|fourth|fifth|sixth|seventh|eighth|ninth"
        // Fixed pattern, so a throw here is a programming error, not input data.
        return try! NSRegularExpression(
            pattern: "(?<!-)\\b(\(tens))-(\(units)|\(ordinals))\\b(?!-)",
            options: [.caseInsensitive]
        )
    }()

    /// Version of the linked native engine, for diagnostics.
    public static var engineVersion: String {
        guard let version = nemo_version() else { return "unknown" }
        return String(cString: version)
    }
}
