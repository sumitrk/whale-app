import Foundation
import TextProcessing

/// Rewrites the spoken forms a transcription model produces into the written
/// forms a reader expects — "twenty one dollars and fifty cents" becomes
/// "$21.50", "january fifth twenty twenty five" becomes "january 5 2025".
///
/// Runs after transcription, on the text rather than the audio, so it never
/// touches `rawTranscript`. The stage is recoverable and returns the transcript
/// untouched whenever the rewrite produces nothing usable: a mangled figure is
/// an annoyance, an empty insertion is a lost dictation.
struct SmartFormattingStage: PipelineStage {
    let name = "Formatting"
    let isRecoverable = true

    private let format: @Sendable (String) -> String

    init(format: @escaping @Sendable (String) -> String = Self.defaultFormat) {
        self.format = format
    }

    /// Engine defaults, minus the bare-ordinal rewrite: dictation says "give me
    /// a second" far more often than it means "2nd".
    static let defaultFormat: @Sendable (String) -> String = { text in
        SpokenFormNormalizer.writtenForm(text, keepBareSecond: true)
    }

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        guard !context.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return context
        }

        let formatted = format(context.transcript)
        guard !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return context
        }

        var updated = context
        updated.transcript = formatted
        return updated
    }
}
