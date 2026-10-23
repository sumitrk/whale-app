import Foundation

/// How formal Clean Up makes the text: from texting style to no contractions.
enum CleanUpStyle: String, CaseIterable, Identifiable {
    case casual
    case semiCasual = "semi-casual"
    case semiFormal = "semi-formal"
    case formal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .casual: "Casual"
        case .semiCasual: "Relaxed"
        case .semiFormal: "Standard"
        case .formal: "Formal"
        }
    }

    /// The same sentence in each style, shown under the picker.
    var example: String {
        switch self {
        case .casual: "hmm im gonna be late. theres a cute dog outside. i cant just walk past him"
        case .semiCasual: "hmm, I'm gonna be late. there's a cute dog outside. I can't just walk past him"
        case .semiFormal: "I'm going to be late. There's a cute dog outside. I can't just walk past him."
        case .formal: "I am going to be late. There is a cute dog outside. I cannot just walk past him."
        }
    }
}
