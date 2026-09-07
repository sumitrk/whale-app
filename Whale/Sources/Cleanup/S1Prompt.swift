import Foundation

/// Builds the exact prompt string S1-mini was trained on.
///
/// The chat template ships with the model as Jinja, but there is no reason to run a
/// template engine over a fixed three-turn conversation: the model card publishes the
/// literal string, and writing it out means the two things every S1 integration gets
/// wrong — the system prompt's wording and the empty think block — are visible in one
/// place rather than hidden behind template arguments.
enum S1Prompt {

    /// Required verbatim. The model was never trained without it, and rewording it is
    /// indistinguishable, from the model's side, from prompting a different model.
    static let systemPrompt = """
        You are a text normalizer for speech-to-text transcripts. The input begins with a \
        control line specifying the styling, structure, and context settings; clean the \
        transcript to match those settings and output only the cleaned text.
        """

    /// Qwen3's template turns thinking on by default and S1-mini was trained with it off,
    /// so the assistant turn has to open with an already-closed, empty think block. Leave
    /// it out and the model emits `<think>` and stops, which is the single most common way
    /// to get a blank result out of it.
    ///
    /// Two newlines inside the block, two more after it.
    static let assistantPrefix = "<|im_start|>assistant\n<think>\n\n</think>\n\n"

    static func prompt(for transcript: String, options: TranscriptCleanupOptions) -> String {
        """
        <|im_start|>system
        \(systemPrompt)<|im_end|>
        <|im_start|>user
        \(options.controlLine)
        \(transcript)<|im_end|>
        \(assistantPrefix)
        """
    }

    /// Output length tracks input length closely, so the generation budget is sized from
    /// the prompt rather than left at a flat ceiling — the model card's `1.3 × input + 32`.
    /// A budget that is merely generous costs seconds on every dictation.
    static func maxTokens(forPromptTokenCount count: Int) -> Int {
        Int(Double(count) * 1.3) + 32
    }
}

/// Splits an over-long transcript into passes the model can take one at a time.
///
/// S1-mini is built for dictation-length input and the card asks for single passes under
/// roughly 1,000 tokens. Rather than tokenize twice — once to measure, once to run — the
/// budget is spent in characters, at a deliberately pessimistic ~4 characters per token.
enum S1Chunker {

    /// ~600 tokens of transcript, leaving the control line, system prompt and the model's
    /// own output comfortably inside the trained range.
    static let defaultBudget = 2400

    /// Sentence-aligned chunks, each at most `budget` characters — except a single
    /// sentence longer than the budget, which is passed whole. Splitting mid-sentence
    /// would hand the model an input unlike anything it was trained on, which is a worse
    /// failure than one oversized pass.
    static func chunks(_ text: String, budget: Int = defaultBudget) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > budget else {
            return trimmed.isEmpty ? [] : [trimmed]
        }

        var chunks: [String] = []
        var current = ""

        for sentence in sentences(in: trimmed) {
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= budget {
                current += " " + sentence
            } else {
                chunks.append(current)
                current = sentence
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    /// Sentence boundaries as the transcript actually presents them. ASR output is often
    /// unpunctuated, in which case this returns the whole thing as one "sentence" and the
    /// oversized-pass branch above takes over — correct, because there is no boundary to
    /// cut on that the model would recognize.
    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""

        for character in text {
            current.append(character)

            if character == "." || character == "!" || character == "?" || character == "\n" {
                let candidate = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    result.append(candidate)
                }
                current = ""
            }
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            result.append(tail)
        }

        return result
    }
}
