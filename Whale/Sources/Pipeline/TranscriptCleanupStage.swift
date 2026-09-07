import Foundation

/// Rewrites the transcript with S1-mini: fillers removed, false starts resolved to what
/// the speaker landed on, punctuation and capitalization applied, and spoken numbers,
/// dates, money and email addresses written the way they would be typed.
///
/// Sits in the same slot `SmartFormattingStage` occupies and does a superset of its work,
/// so the two are alternatives rather than a chain — running both would have the rewriter
/// re-read text a regex engine had already reshaped.
///
/// Recoverable, and aggressively so. Every failure here — a model that will not load, a
/// pass that runs long, a rewrite that does not look like its input — resolves to the raw
/// transcript rather than to an error, because the alternative is a dictation the user
/// spoke and cannot get back.
struct TranscriptCleanupStage: PipelineStage {
    let name = "Cleanup"
    let isRecoverable = true

    private let engine: any TranscriptCleanupEngine
    private let options: TranscriptCleanupOptions
    private let budget: Duration

    /// Long enough for a couple of chunked passes on a slower Mac, short enough that a
    /// wedged runtime does not hold a dictation hostage.
    static let defaultBudget = Duration.seconds(20)

    init(
        engine: any TranscriptCleanupEngine,
        options: TranscriptCleanupOptions = .default,
        budget: Duration = Self.defaultBudget
    ) {
        self.engine = engine
        self.options = options
        self.budget = budget
    }

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        let raw = context.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return context }

        let options = self.options
        let chunks = S1Chunker.chunks(raw)
        guard !chunks.isEmpty else { return context }

        let cleaned = try await withDeadline(budget) {
            var passes: [String] = []
            for chunk in chunks {
                passes.append(try await engine.clean(chunk, options: options))
            }
            return passes.joined(separator: "\n\n")
        }

        guard let accepted = TranscriptCleanupGuard.accept(cleaned: cleaned, raw: raw) else {
            throw TranscriptCleanupError.rejected
        }

        var updated = context
        updated.transcript = accepted
        return updated
    }

    /// Races the work against the budget. The losing side is cancelled, which for a
    /// generation loop means it stops at its next token rather than at some later
    /// checkpoint.
    private func withDeadline<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TranscriptCleanupError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TranscriptCleanupError.timedOut
            }
            return result
        }
    }
}
