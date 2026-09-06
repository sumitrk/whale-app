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
        text.withCString { input in
            guard let result = nemo_normalize_sentence_with_options(
                input,
                concatCompoundNumbers ? 1 : 0,
                maxSpanTokens,
                keepBareSecond ? 1 : 0
            ) else {
                return text
            }
            defer { nemo_free_string(result) }
            return String(cString: result)
        }
    }

    /// Version of the linked native engine, for diagnostics.
    public static var engineVersion: String {
        guard let version = nemo_version() else { return "unknown" }
        return String(cString: version)
    }
}
