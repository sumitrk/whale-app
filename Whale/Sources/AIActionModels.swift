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
    let inputs: [ContextInput]
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
    let instructionText: String?
    let resultText: String?
    let errorText: String?
    let contextInputs: [ContextInput]
}

enum SHA256Digest {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
