import FluidAudio
import Foundation

/// Rule-based Clean Up (`RuleCleanUp`): spoken commands, self-corrections, stutters, lists,
/// email layout and the chosen style. Recoverable, and keeps the transcript it was given when
/// the result doesn't look like a cleanup of it. Meetings (system audio) are left alone: the
/// rules are for something one person dictated.
struct CleanUpStage: PipelineStage {
    let name = "Clean up"
    let isRecoverable = true

    let style: CleanUpStyle
    let allowLists: Bool
    let context: CleanUpContext

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        let input = context.transcript
        guard context.audioSource == .microphone, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return context }

        let cleaned = RuleCleanUp.clean(input, style: style, allowLists: allowLists, context: self.context)
        guard RewriteCheck.isPlausible(cleaned, of: input) else {
            var updated = context
            updated.warnings.append("\(name): discarded an implausible rewrite")
            return updated
        }
        // An empty result is a filler-only recording ("um"), which nothing should be typed for.
        var updated = context
        updated.transcript = cleaned
        return updated
    }
}
