import Foundation

/// Whether a rewritten transcript still says what was said. From Kaze (MIT).
enum RewriteCheck {
    /// False for a failure mode: blank output for real speech, runaway output, or output
    /// that is mostly new words.
    static func isPlausible(_ output: String, of input: String) -> Bool {
        let inputWords = words(in: input)
        let outputWords = words(in: output)
        if outputWords.isEmpty { return inputWords.count <= 3 }   // filler-only input legitimately becomes ""
        guard outputWords.count <= inputWords.count * 2 + 12 else { return false }
        // A cleanup reuses the speaker's words. Numbers and symbols are exempt
        // ("forty two" → "42").
        let spoken = Set(inputWords)
        let novel = outputWords.filter { word in
            !spoken.contains(word) && !word.allSatisfy { $0.isNumber || $0.isPunctuation || $0.isSymbol }
        }
        return Double(novel.count) <= max(3, Double(outputWords.count) * 0.4)
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "@.$")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }
}
