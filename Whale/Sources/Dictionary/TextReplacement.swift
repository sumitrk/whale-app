import Foundation

/// A phrase the user says and the text Whale types for it instead.
struct TextReplacement: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var spoken: String
    var written: String
}
