import Foundation

/// Where a capture starts its History Entry.
@MainActor
protocol CaptureHistory: AnyObject {
    func begin(_ kind: HistoryKind, sourceAppName: String?, sourceAppBundleID: String?) async throws -> HistoryEntryHandle
}

extension HistoryController: CaptureHistory {}
