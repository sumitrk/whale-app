import Foundation

/// The user's own words, applied to a transcript after the model and formatting are done.
///
/// - Vocabulary: names and jargon spelled the user's way. A word, or a run of up to three
///   words, matching a term with letters and digits alone is respelled: "x code" becomes
///   "Xcode", "kubernetes" becomes "Kubernetes". Near misses of longer terms are respelled
///   too ("olama" → "Ollama"), but only when they start with the same letter and are within an
///   edit or two, so ordinary words aren't pulled toward a term.
/// - Replacements: a spoken phrase swapped for exactly the text the user wants, matched
///   whole-word and case-insensitively, allowing a comma between its words.
///
/// Vocabulary runs first, so a replacement's output — an email address, a kaomoji — is never
/// respelled afterwards.
struct PersonalDictionary: Sendable {
    var vocabulary: [String]
    var replacements: [TextReplacement]

    var isEmpty: Bool { vocabulary.isEmpty && replacements.isEmpty }

    func apply(to text: String) -> String {
        replacing(in: respelling(text))
    }

    // MARK: Vocabulary

    private struct Term {
        let spelling: String
        let key: String
        let wordCount: Int
    }

    private struct Word {
        let range: Range<String.Index>
        let key: String
    }

    func respelling(_ text: String) -> String {
        let terms: [Term] = vocabulary.compactMap { spelling in
            let trimmed = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Self.key(trimmed)
            guard !key.isEmpty else { return nil }
            return Term(spelling: trimmed, key: key, wordCount: Self.words(in: trimmed).count)
        }
        guard !terms.isEmpty else { return text }

        let words = Self.words(in: text)
        var edits: [(Range<String.Index>, String)] = []
        var index = 0
        while index < words.count {
            if let match = bestMatch(at: index, in: words, text: text, terms: terms) {
                let range = words[index].range.lowerBound..<words[index + match.length - 1].range.upperBound
                if text[range] != match.term.spelling {
                    edits.append((range, match.term.spelling))
                }
                index += match.length
            } else {
                index += 1
            }
        }

        var result = text
        for (range, spelling) in edits.reversed() {
            result.replaceSubrange(range, with: spelling)
        }
        return result
    }

    /// The term the words starting at `start` spell, preferring an exact spelling, then the
    /// closest, then the longest run of words.
    private func bestMatch(at start: Int, in words: [Word], text: String, terms: [Term]) -> (term: Term, length: Int)? {
        var best: (term: Term, length: Int, distance: Int)?
        var joined = ""
        for length in 1...3 {
            let end = start + length - 1
            guard end < words.count else { break }
            // Words join only across spaces or hyphens: "x code", "x-code", not "x. Code".
            if length > 1, !Self.isJoiner(text[words[end - 1].range.upperBound..<words[end].range.lowerBound]) { break }
            joined += words[end].key

            for term in terms {
                guard let distance = Self.matchDistance(joined, term.key) else { continue }
                // An inexact match only over as many words as the term has, or one more.
                if distance > 0, length > term.wordCount + 1 { continue }
                if let current = best, (distance, -length) >= (current.distance, -current.length) { continue }
                best = (term, length, distance)
            }
        }
        return best.map { ($0.term, $0.length) }
    }

    private static func matchDistance(_ candidate: String, _ key: String) -> Int? {
        if candidate == key { return 0 }
        let allowed: Int
        switch key.count {
        case ..<5: return nil
        case 5..<8: allowed = 1
        default: allowed = 2
        }
        guard candidate.first == key.first, abs(candidate.count - key.count) <= allowed else { return nil }
        let distance = editDistance(Array(candidate), Array(key), limit: allowed)
        return distance <= allowed ? distance : nil
    }

    /// Levenshtein distance, giving up once every path is past `limit`.
    private static func editDistance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            if current.allSatisfy({ $0 > limit }) { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }

    private static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var start: String.Index?
        for index in text.indices {
            let isWordCharacter = text[index].isLetter || text[index].isNumber
            if isWordCharacter, start == nil {
                start = index
            } else if !isWordCharacter, let wordStart = start {
                words.append(Word(range: wordStart..<index, key: key(text[wordStart..<index])))
                start = nil
            }
        }
        if let start {
            words.append(Word(range: start..<text.endIndex, key: key(text[start...])))
        }
        return words
    }

    private static func key<S: StringProtocol>(_ text: S) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func isJoiner(_ gap: Substring) -> Bool {
        !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "-" }
    }

    // MARK: Replacements

    func replacing(in text: String) -> String {
        var result = text
        // Longest first, so "be right back" wins over a shorter "be right".
        for replacement in replacements.sorted(by: { $0.spoken.count > $1.spoken.count }) {
            guard let pattern = Self.pattern(for: replacement.spoken) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement.written)
            )
        }
        return result
    }

    private static func pattern(for spoken: String) -> NSRegularExpression? {
        let parts = spoken
            .split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        let body = parts.joined(separator: #"[\s,\-]+"#)
        return try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])"# + body + #"(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]
        )
    }
}
