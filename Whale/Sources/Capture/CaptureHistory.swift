import AppKit
import Foundation

/// The History Entry writes a capture makes, start to finish.
@MainActor
protocol CaptureHistory: AnyObject {
    func createEntry(kind: HistoryKind, sourceAppName: String?, sourceAppBundleID: String?) async throws -> UUID
    func setContext(_ snapshot: ContextSnapshot, for id: UUID) async throws
    func setInstruction(_ text: String, for id: UUID) async throws
    func finalize(
        _ id: UUID,
        outcome: HistoryOutcome,
        instructionText: String?,
        resultText: String?,
        errorText: String?,
        audioSeconds: Double?
    ) async
}

extension HistoryController: CaptureHistory {
    func createEntry(kind: HistoryKind, sourceAppName: String?, sourceAppBundleID: String?) async throws -> UUID {
        let id = try await requireStore().createEntry(
            kind: kind,
            sourceAppName: sourceAppName,
            sourceAppBundleID: sourceAppBundleID
        )
        changed()
        return id
    }

    func setContext(_ snapshot: ContextSnapshot, for id: UUID) async throws {
        try await requireStore().setContext(snapshot, for: id)
        changed()
    }

    func setInstruction(_ text: String, for id: UUID) async throws {
        try await requireStore().setInstruction(text, for: id)
        changed()
    }

    func finalize(
        _ id: UUID,
        outcome: HistoryOutcome,
        instructionText: String?,
        resultText: String?,
        errorText: String?,
        audioSeconds: Double?
    ) async {
        guard let store = try? await requireStore() else { return }
        try? await store.finalize(
            id,
            outcome: outcome,
            instructionText: instructionText,
            resultText: resultText,
            errorText: errorText,
            audioSeconds: audioSeconds
        )
        changed()
    }
}
