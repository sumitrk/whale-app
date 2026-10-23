import XCTest
@testable import Whale

/// The History module against a temporary SQLCipher file.
@MainActor
final class HistoryControllerTests: XCTestCase {
    private var directory: URL!
    private var history: HistoryController!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhaleHistoryControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        history = Self.controller(in: directory)
    }

    override func tearDown() async throws {
        history = nil
        try? FileManager.default.removeItem(at: directory)
    }

    static func controller(in directory: URL) -> HistoryController {
        let url = directory.appendingPathComponent("History.sqlite3")
        let key = Data(repeating: 0x5A, count: 32)
        return HistoryController(
            open: { try await HistoryStore.open(url: url, key: key) },
            reset: { try await HistoryStore.open(url: url, key: key) }
        )
    }

    func testAnEntryRunsUntilItsHandleFinishes() async throws {
        let entry = try await history.begin(.dictation, sourceAppName: "Notes", sourceAppBundleID: "com.apple.Notes")
        let running = try await history.entry(id: entry.id)
        XCTAssertEqual(running?.outcome, .running)

        await entry.finish(.succeeded, instruction: "hello", result: "hello", error: nil, audioSeconds: 1.5)

        let stored = try await history.entry(id: entry.id)
        XCTAssertEqual(stored?.outcome, .succeeded)
        XCTAssertEqual(stored?.resultText, "hello")
        XCTAssertEqual(stored?.sourceAppName, "Notes")
    }

    func testOnlyTheFirstOutcomeCounts() async throws {
        let entry = try await history.begin(.aiAction, sourceAppName: nil, sourceAppBundleID: nil)
        await entry.finish(.cancelled, instruction: nil, result: nil, error: "Cancelled", audioSeconds: nil)
        await entry.finish(.failed, instruction: nil, result: nil, error: "Late failure", audioSeconds: nil)

        let stored = try await history.entry(id: entry.id)
        XCTAssertEqual(stored?.outcome, .cancelled)
        XCTAssertEqual(stored?.errorText, "Cancelled")
    }

    func testEveryWritePublishesAChange() async throws {
        var revisions: [Int] = []
        let subscription = history.$revision.dropFirst().sink { revisions.append($0) }
        defer { subscription.cancel() }

        let entry = try await history.begin(.aiAction, sourceAppName: nil, sourceAppBundleID: nil)
        try await entry.setContext(ContextSnapshot(capturedAt: .now, sourceAppName: "Mail", inputs: []))
        try await entry.setInstruction("Summarise this")
        await entry.finish(.succeeded, instruction: nil, result: "Done", error: nil, audioSeconds: nil)
        try await history.delete(id: entry.id)

        XCTAssertEqual(revisions.count, 5, "begin, context, instruction, finish, delete")
        let remaining = try await history.entries()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAStoreThatWontOpenIsReportedNotSwallowed() async {
        let locked = HistoryController(open: { throw HistoryStoreError.locked }, reset: { throw HistoryStoreError.locked })

        do {
            _ = try await locked.begin(.dictation, sourceAppName: nil, sourceAppBundleID: nil)
            XCTFail("Expected the open to fail")
        } catch {}
        XCTAssertEqual(locked.errorMessage, HistoryStoreError.locked.localizedDescription)
    }
}
