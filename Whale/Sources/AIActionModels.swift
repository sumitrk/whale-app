import CryptoKit
import Foundation

struct ContextImage: Sendable, Equatable, Identifiable {
    let data: Data
    let mediaType: String

    var id: String { contentHash }
    var contentHash: String { SHA256Digest.hex(data) }
}

struct ContextInput: Sendable, Equatable, Identifiable {
    enum Source: String, Sendable, Codable {
        case selection
        case clipboard
    }

    enum Content: Sendable, Equatable {
        case text(String)
        case image(ContextImage)
    }

    let id: UUID
    let source: Source
    let ordinal: Int
    let content: Content

    init(id: UUID = UUID(), source: Source, ordinal: Int, content: Content) {
        self.id = id
        self.source = source
        self.ordinal = ordinal
        self.content = content
    }
}

struct ContextSnapshot: Sendable, Equatable {
    let capturedAt: Date
    let sourceAppName: String?
    /// The source app's bundle identifier, when we could read it. Names are a
    /// poor key for finding an app on disk; this is the one LaunchServices
    /// actually indexes.
    let sourceAppBundleID: String?
    let inputs: [ContextInput]

    init(
        capturedAt: Date,
        sourceAppName: String?,
        sourceAppBundleID: String? = nil,
        inputs: [ContextInput]
    ) {
        self.capturedAt = capturedAt
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.inputs = inputs
    }
}

enum HistoryKind: String, Sendable, Codable {
    case dictation
    case aiAction = "ai_action"
}

enum HistoryOutcome: String, Sendable, Codable {
    case running
    case succeeded
    case failed
    case cancelled
}

struct HistoryEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let kind: HistoryKind
    let createdAt: Date
    let completedAt: Date?
    let outcome: HistoryOutcome
    let sourceAppName: String?
    let sourceAppBundleID: String?
    let instructionText: String?
    let resultText: String?
    let errorText: String?
    let contextInputs: [ContextInput]

    init(
        id: UUID,
        kind: HistoryKind,
        createdAt: Date,
        completedAt: Date?,
        outcome: HistoryOutcome,
        sourceAppName: String?,
        sourceAppBundleID: String? = nil,
        instructionText: String?,
        resultText: String?,
        errorText: String?,
        contextInputs: [ContextInput]
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.outcome = outcome
        self.sourceAppName = sourceAppName
        self.sourceAppBundleID = sourceAppBundleID
        self.instructionText = instructionText
        self.resultText = resultText
        self.errorText = errorText
        self.contextInputs = contextInputs
    }

    var listTitle: String {
        let name = sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Unknown App" : name
    }

    var listPreview: String {
        [resultText, instructionText, errorText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    var isDimmedInList: Bool {
        outcome == .failed || outcome == .cancelled
    }
}

enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
