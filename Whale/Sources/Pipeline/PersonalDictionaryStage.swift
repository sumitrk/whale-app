import Foundation

/// Spells the user's vocabulary their way and applies their replacements. The last stage, so
/// it sees the finished text; recoverable, and a no-op when the dictionary is empty.
struct PersonalDictionaryStage: PipelineStage {
    let name = "Dictionary"
    let isRecoverable = true

    let dictionary: PersonalDictionary

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        guard !dictionary.isEmpty else { return context }
        let applied = dictionary.apply(to: context.transcript)
        guard !applied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return context }
        var updated = context
        updated.transcript = applied
        return updated
    }
}
