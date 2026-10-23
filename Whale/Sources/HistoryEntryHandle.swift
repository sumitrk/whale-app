import Foundation

/// A History Entry in progress, as a capture writes to it. `LiveHistoryEntry` in the app.
@MainActor
protocol HistoryEntryHandle: AnyObject {
    var id: UUID { get }
    func setContext(_ snapshot: ContextSnapshot) async throws
    func setInstruction(_ text: String) async throws
    /// Records the outcome; later calls are ignored.
    func finish(
        _ outcome: HistoryOutcome,
        instruction: String?,
        result: String?,
        error: String?,
        audioSeconds: Double?
    ) async
}
