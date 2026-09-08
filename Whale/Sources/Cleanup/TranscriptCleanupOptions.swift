import Foundation

/// The three steering axes S1-mini was trained on. Every input carries one value from
/// each, on a control line above the transcript.
///
/// The raw values are the literal strings the model expects, and the model was only
/// ever trained on these — a value outside the set makes it hallucinate rather than
/// fail, so nothing here may be invented, translated, or prettified on the way out.

enum TranscriptCleanupStyling: String, CaseIterable, Codable, Identifiable, Sendable {
    case casual
    case semiCasual = "semi-casual"
    case semiFormal = "semi-formal"
    case formal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .casual:     return "Casual"
        case .semiCasual: return "Semi-casual"
        case .semiFormal: return "Semi-formal"
        case .formal:     return "Formal"
        }
    }

    var detail: String {
        switch self {
        case .casual:     return "all lowercase, apostrophes dropped"
        case .semiCasual: return "your phrasing kept, sentences left lowercase"
        case .semiFormal: return "standard written English, contractions kept"
        case .formal:     return "standard written English, contractions expanded"
        }
    }
}

enum TranscriptCleanupStructure: String, CaseIterable, Codable, Identifiable, Sendable {
    case prose
    case lists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .prose: return "Prose"
        case .lists: return "Allow lists"
        }
    }

    var detail: String {
        switch self {
        case .prose: return "everything stays in sentences"
        case .lists: return "three or more enumerated items may become bullets"
        }
    }
}

enum TranscriptCleanupContext: String, CaseIterable, Codable, Identifiable, Sendable {
    case general
    case email

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .email:   return "Email"
        }
    }

    var detail: String {
        switch self {
        case .general: return "flowing text"
        case .email:   return "greeting, body, and sign-off block"
        }
    }
}

struct TranscriptCleanupOptions: Equatable, Sendable {
    var styling: TranscriptCleanupStyling
    var structure: TranscriptCleanupStructure
    var context: TranscriptCleanupContext

    /// What the model card calls "a good default": full capitalization and punctuation
    /// with the speaker's contractions left alone.
    static let `default` = TranscriptCleanupOptions(
        styling: .semiFormal,
        structure: .prose,
        context: .general
    )

    /// The literal control line, exactly as trained. Order and spacing are part of the
    /// input format, not a presentation choice.
    var controlLine: String {
        "[Styling: \(styling.rawValue)] [Structure: \(structure.rawValue)] [Context: \(context.rawValue)]"
    }
}
