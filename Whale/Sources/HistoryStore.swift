import Combine
import Foundation
import Security
import SQLCipher

enum HistoryStoreError: LocalizedError {
    case locked
    case database(String)

    var errorDescription: String? {
        switch self {
        case .locked:
            return "History can't be unlocked"
        case .database(let message):
            return message
        }
    }
}

actor HistoryStore {
    private let url: URL
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init(url: URL) throws {
        self.url = url
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            throw HistoryStoreError.database("History could not be opened")
        }
        db = connection
    }

    private func configure(key: Data) throws {
        do {
            let hexKey = key.map { String(format: "%02x", $0) }.joined()
            try execute("PRAGMA key = \"x'\(hexKey)'\"")
            guard try scalarText("PRAGMA cipher_version")?.isEmpty == false else {
                throw HistoryStoreError.database("SQLCipher encryption is unavailable")
            }
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA secure_delete = ON")
            try migrate()
        } catch {
            sqlite3_close(db)
            db = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(db)
    }

    static func openDefault() async throws -> HistoryStore {
        let directory = try historyDirectory()
        let url = directory.appendingPathComponent("History.sqlite3")
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        let key: Data

        if let existing = try KeychainStore.data(for: .historyDatabaseKey) {
            key = existing
        } else {
            guard !fileExists else { throw HistoryStoreError.locked }
            var generated = Data(count: 32)
            let status = generated.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw HistoryStoreError.database("A History encryption key could not be created")
            }
            try KeychainStore.set(generated, for: .historyDatabaseKey)
            key = generated
        }

        let store = try HistoryStore(url: url)
        do {
            try await store.configure(key: key)
            return store
        } catch {
            if fileExists { throw HistoryStoreError.locked }
            throw error
        }
    }

    static func open(url: URL, key: Data) async throws -> HistoryStore {
        let store = try HistoryStore(url: url)
        try await store.configure(key: key)
        return store
    }

    static func resetDefault() async throws -> HistoryStore {
        let directory = try historyDirectory()
        for name in ["History.sqlite3", "History.sqlite3-shm", "History.sqlite3-wal"] {
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        }
        try KeychainStore.delete(.historyDatabaseKey)
        return try await openDefault()
    }

    func createEntry(
        kind: HistoryKind,
        sourceAppName: String? = nil,
        contextInputs: [ContextInput] = []
    ) throws -> UUID {
        let id = UUID()
        try transaction {
            try withStatement(
                "INSERT INTO history_entries (id, kind, created_at, outcome, source_app_name) VALUES (?, ?, ?, ?, ?)"
            ) { statement in
                bind(id.uuidString, to: 1, in: statement)
                bind(kind.rawValue, to: 2, in: statement)
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                bind(HistoryOutcome.running.rawValue, to: 4, in: statement)
                bind(sourceAppName, to: 5, in: statement)
                try stepDone(statement)
            }
            try insert(contextInputs, entryID: id)
            try updateFTS(entryID: id)
        }
        return id
    }

    func setInstruction(_ text: String, for id: UUID) throws {
        try withStatement("UPDATE history_entries SET instruction_text = ? WHERE id = ?") { statement in
            bind(text, to: 1, in: statement)
            bind(id.uuidString, to: 2, in: statement)
            try stepDone(statement)
        }
        try updateFTS(entryID: id)
    }

    func setContext(_ snapshot: ContextSnapshot, for id: UUID) throws {
        try transaction {
            try withStatement("UPDATE history_entries SET source_app_name = ? WHERE id = ?") { statement in
                bind(snapshot.sourceAppName, to: 1, in: statement)
                bind(id.uuidString, to: 2, in: statement)
                try stepDone(statement)
            }
            try insert(snapshot.inputs, entryID: id)
            try updateFTS(entryID: id)
        }
    }

    func finalize(
        _ id: UUID,
        outcome: HistoryOutcome,
        instructionText: String? = nil,
        resultText: String? = nil,
        errorText: String? = nil
    ) throws {
        try transaction {
            try withStatement(
                """
                UPDATE history_entries
                SET completed_at = ?, outcome = ?,
                    instruction_text = COALESCE(?, instruction_text), result_text = ?, error_text = ?
                WHERE id = ?
                """
            ) { statement in
                sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
                bind(outcome.rawValue, to: 2, in: statement)
                bind(instructionText, to: 3, in: statement)
                bind(resultText, to: 4, in: statement)
                bind(errorText, to: 5, in: statement)
                bind(id.uuidString, to: 6, in: statement)
                try stepDone(statement)
            }
            try updateFTS(entryID: id)
        }
    }

    func entries(search query: String = "", limit: Int = 200) throws -> [HistoryEntry] {
        let terms = ftsTerms(query)
        let sql: String
        if terms.isEmpty {
            sql = """
                SELECT id, kind, created_at, completed_at, outcome, source_app_name,
                       instruction_text, result_text, error_text
                FROM history_entries ORDER BY created_at DESC LIMIT ?
                """
        } else {
            sql = """
                SELECT e.id, e.kind, e.created_at, e.completed_at, e.outcome, e.source_app_name,
                       e.instruction_text, e.result_text, e.error_text
                FROM history_fts f JOIN history_entries e ON e.id = f.entry_id
                WHERE history_fts MATCH ? ORDER BY bm25(history_fts), e.created_at DESC LIMIT ?
                """
        }

        return try withStatement(sql) { statement in
            var index: Int32 = 1
            if !terms.isEmpty {
                bind(terms, to: index, in: statement)
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(limit))
            var values: [HistoryEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(entry(from: statement, contextInputs: []))
            }
            return values
        }
    }

    func entry(id: UUID) throws -> HistoryEntry? {
        try withStatement(
            """
            SELECT id, kind, created_at, completed_at, outcome, source_app_name,
                   instruction_text, result_text, error_text
            FROM history_entries WHERE id = ?
            """
        ) { statement in
            bind(id.uuidString, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return entry(from: statement, contextInputs: try inputs(entryID: id))
        }
    }

    func deleteEntry(id: UUID) throws {
        try transaction {
            try withStatement("DELETE FROM history_fts WHERE entry_id = ?") { statement in
                bind(id.uuidString, to: 1, in: statement)
                try stepDone(statement)
            }
            try withStatement("DELETE FROM history_entries WHERE id = ?") { statement in
                bind(id.uuidString, to: 1, in: statement)
                try stepDone(statement)
            }
            try execute("DELETE FROM images WHERE content_hash NOT IN (SELECT image_hash FROM context_inputs WHERE image_hash IS NOT NULL)")
        }
    }

    func clear() throws {
        try transaction {
            try execute("DELETE FROM history_fts")
            try execute("DELETE FROM history_entries")
            try execute("DELETE FROM images")
        }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    func storageBytes() -> Int64 {
        let names = [url.lastPathComponent, url.lastPathComponent + "-wal", url.lastPathComponent + "-shm"]
        return names.reduce(0) { total, name in
            let file = url.deletingLastPathComponent().appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    func imageCount() throws -> Int {
        try withStatement("SELECT count(*) FROM images") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    func checkpoint() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS history_entries (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                created_at REAL NOT NULL,
                completed_at REAL,
                outcome TEXT NOT NULL,
                source_app_name TEXT,
                instruction_text TEXT,
                result_text TEXT,
                error_text TEXT
            );
            CREATE TABLE IF NOT EXISTS images (
                content_hash TEXT PRIMARY KEY,
                media_type TEXT NOT NULL,
                original_bytes BLOB NOT NULL,
                byte_count INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS context_inputs (
                id TEXT PRIMARY KEY,
                entry_id TEXT NOT NULL REFERENCES history_entries(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                media_type TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                text_value TEXT,
                image_hash TEXT REFERENCES images(content_hash)
            );
            CREATE INDEX IF NOT EXISTS context_entry_index ON context_inputs(entry_id, source, ordinal);
            CREATE VIRTUAL TABLE IF NOT EXISTS history_fts USING fts5(
                entry_id UNINDEXED, instruction_text, result_text,
                selected_text, clipboard_text, source_app_name
            );
            PRAGMA user_version = 1;
            """
        )
    }

    private func insert(_ inputs: [ContextInput], entryID: UUID) throws {
        for input in inputs {
            var textValue: String?
            var imageHash: String?
            var mediaType: String
            switch input.content {
            case .text(let text):
                textValue = text
                mediaType = "text/plain"
            case .image(let image):
                imageHash = image.contentHash
                mediaType = image.mediaType
                try withStatement(
                    "INSERT OR IGNORE INTO images (content_hash, media_type, original_bytes, byte_count) VALUES (?, ?, ?, ?)"
                ) { statement in
                    bind(imageHash, to: 1, in: statement)
                    bind(image.mediaType, to: 2, in: statement)
                    _ = image.data.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), Self.transient)
                    }
                    sqlite3_bind_int64(statement, 4, sqlite3_int64(image.data.count))
                    try stepDone(statement)
                }
            }

            try withStatement(
                "INSERT INTO context_inputs (id, entry_id, source, media_type, ordinal, text_value, image_hash) VALUES (?, ?, ?, ?, ?, ?, ?)"
            ) { statement in
                bind(input.id.uuidString, to: 1, in: statement)
                bind(entryID.uuidString, to: 2, in: statement)
                bind(input.source.rawValue, to: 3, in: statement)
                bind(mediaType, to: 4, in: statement)
                sqlite3_bind_int(statement, 5, Int32(input.ordinal))
                bind(textValue, to: 6, in: statement)
                bind(imageHash, to: 7, in: statement)
                try stepDone(statement)
            }
        }
    }

    private func inputs(entryID: UUID) throws -> [ContextInput] {
        try withStatement(
            """
            SELECT c.id, c.source, c.ordinal, c.text_value, c.media_type, i.original_bytes
            FROM context_inputs c LEFT JOIN images i ON i.content_hash = c.image_hash
            WHERE c.entry_id = ? ORDER BY c.source, c.ordinal
            """
        ) { statement in
            bind(entryID.uuidString, to: 1, in: statement)
            var values: [ContextInput] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idText = text(statement, 0), let id = UUID(uuidString: idText),
                      let sourceText = text(statement, 1), let source = ContextInput.Source(rawValue: sourceText) else { continue }
                let ordinal = Int(sqlite3_column_int(statement, 2))
                if let value = text(statement, 3) {
                    values.append(ContextInput(id: id, source: source, ordinal: ordinal, content: .text(value)))
                } else if let bytes = blob(statement, 5) {
                    values.append(ContextInput(
                        id: id,
                        source: source,
                        ordinal: ordinal,
                        content: .image(ContextImage(data: bytes, mediaType: text(statement, 4) ?? "image/png"))
                    ))
                }
            }
            return values
        }
    }

    private func updateFTS(entryID: UUID) throws {
        try withStatement("DELETE FROM history_fts WHERE entry_id = ?") { statement in
            bind(entryID.uuidString, to: 1, in: statement)
            try stepDone(statement)
        }
        try withStatement(
            """
            INSERT INTO history_fts(entry_id, instruction_text, result_text, selected_text, clipboard_text, source_app_name)
            SELECT e.id, COALESCE(e.instruction_text, ''), COALESCE(e.result_text, ''),
                   COALESCE((SELECT group_concat(text_value, char(10)) FROM context_inputs WHERE entry_id=e.id AND source='selection'), ''),
                   COALESCE((SELECT group_concat(text_value, char(10)) FROM context_inputs WHERE entry_id=e.id AND source='clipboard'), ''),
                   COALESCE(e.source_app_name, '')
            FROM history_entries e WHERE e.id = ?
            """
        ) { statement in
            bind(entryID.uuidString, to: 1, in: statement)
            try stepDone(statement)
        }
    }

    private func entry(from statement: OpaquePointer, contextInputs: [ContextInput]) -> HistoryEntry {
        HistoryEntry(
            id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
            kind: HistoryKind(rawValue: text(statement, 1) ?? "") ?? .dictation,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            completedAt: sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            outcome: HistoryOutcome(rawValue: text(statement, 4) ?? "") ?? .failed,
            sourceAppName: text(statement, 5),
            instructionText: text(statement, 6),
            resultText: text(statement, 7),
            errorText: text(statement, 8),
            contextInputs: contextInputs
        )
    }

    private func ftsTerms(_ query: String) -> String {
        query.split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " ")
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorMessage)
            throw HistoryStoreError.database(message)
        }
    }

    private func scalarText(_ sql: String) throws -> String? {
        try withStatement(sql) { statement in
            sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryStoreError.database(lastError)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryStoreError.database(lastError)
        }
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown History database error"
    }

    private static func historyDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Whale", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
final class HistoryController: ObservableObject {
    static let shared = HistoryController()

    @Published private(set) var errorMessage: String?
    @Published private(set) var revision = 0
    private var store: HistoryStore?

    func prepare() async throws {
        _ = try await requireStore()
    }

    func requireStore() async throws -> HistoryStore {
        if let store { return store }
        do {
            let opened = try await HistoryStore.openDefault()
            store = opened
            errorMessage = nil
            return opened
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func changed() {
        revision &+= 1
    }

    func reset() async throws {
        store = nil
        let opened = try await HistoryStore.resetDefault()
        store = opened
        errorMessage = nil
        changed()
    }
}
