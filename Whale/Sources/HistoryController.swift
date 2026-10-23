import Combine
import Foundation

/// History, as the rest of the app uses it. Opens the encrypted store on first use, hands out
/// a handle for each new History Entry, and publishes every change it makes itself, so a
/// writer can't forget to refresh the History page.
@MainActor
final class HistoryController: ObservableObject {
    static let shared = HistoryController()

    /// Why History couldn't be opened, shown on the History page with a way to reset it.
    @Published private(set) var errorMessage: String?
    /// Bumped after every write.
    @Published private(set) var revision = 0

    private let openStore: () async throws -> HistoryStore
    private let resetStore: () async throws -> HistoryStore
    private var store: HistoryStore?

    /// - Parameters:
    ///   - open: opens the store; the default SQLCipher file in the app, a temporary one in tests.
    ///   - reset: deletes the store and its key, then opens a new one.
    init(
        open: @escaping () async throws -> HistoryStore = { try await HistoryStore.openDefault() },
        reset: @escaping () async throws -> HistoryStore = { try await HistoryStore.resetDefault() }
    ) {
        openStore = open
        resetStore = reset
    }

    func prepare() async throws {
        _ = try await requireStore()
    }

    // MARK: - Entries

    /// Starts a History Entry, `running` until its handle is finished.
    func begin(
        _ kind: HistoryKind,
        sourceAppName: String?,
        sourceAppBundleID: String?
    ) async throws -> HistoryEntryHandle {
        let id = try await write {
            try await $0.createEntry(kind: kind, sourceAppName: sourceAppName, sourceAppBundleID: sourceAppBundleID)
        }
        return LiveHistoryEntry(id: id, history: self)
    }

    func entries(search query: String = "", limit: Int = 200, offset: Int = 0) async throws -> [HistoryEntry] {
        try await requireStore().entries(search: query, limit: limit, offset: offset)
    }

    func entry(id: UUID) async throws -> HistoryEntry? {
        try await requireStore().entry(id: id)
    }

    func dictationStats() async throws -> DictationStats {
        try await requireStore().dictationStats()
    }

    func delete(id: UUID) async throws {
        try await write { try await $0.deleteEntry(id: id) }
    }

    func clear() async throws {
        try await write { try await $0.clear() }
    }

    /// Deletes History and its key and starts over, for a database that can't be unlocked.
    func reset() async throws {
        store = nil
        do {
            store = try await resetStore()
            errorMessage = nil
            revision &+= 1
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Store

    /// Every write goes through here, so every change is published and every failure logged.
    @discardableResult
    func write<T>(_ body: (HistoryStore) async throws -> T) async throws -> T {
        do {
            let result = try await body(requireStore())
            revision &+= 1
            return result
        } catch {
            DiagnosticLog.log("[History] Write failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func requireStore() async throws -> HistoryStore {
        if let store { return store }
        do {
            let opened = try await openStore()
            store = opened
            errorMessage = nil
            return opened
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
