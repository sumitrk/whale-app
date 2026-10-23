import Foundation

/// One History Entry while its Dictation or AI Action runs. Ties the entry's steps together:
/// context and instruction as they arrive, then one outcome. Each write publishes itself.
@MainActor
final class LiveHistoryEntry: HistoryEntryHandle {
    let id: UUID
    private let history: HistoryController
    private(set) var isFinished = false

    init(id: UUID, history: HistoryController) {
        self.id = id
        self.history = history
    }

    func setContext(_ snapshot: ContextSnapshot) async throws {
        try await history.write { try await $0.setContext(snapshot, for: id) }
    }

    func setInstruction(_ text: String) async throws {
        try await history.write { try await $0.setInstruction(text, for: id) }
    }

    /// Records the outcome. Only the first call counts, so a cancel racing a failure keeps
    /// whichever came first. A failed write is logged by the controller.
    func finish(
        _ outcome: HistoryOutcome,
        instruction: String? = nil,
        result: String? = nil,
        error: String? = nil,
        audioSeconds: Double? = nil
    ) async {
        guard !isFinished else { return }
        isFinished = true
        try? await history.write {
            try await $0.finalize(
                id,
                outcome: outcome,
                instructionText: instruction,
                resultText: result,
                errorText: error,
                audioSeconds: audioSeconds
            )
        }
    }
}
