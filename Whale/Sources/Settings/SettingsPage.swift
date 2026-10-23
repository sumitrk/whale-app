import SwiftUI

/// The pages of the Settings window, in the groups the sidebar shows them in.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case models
    case vocabulary
    case replacements
    case aiActions
    case history
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .models: "Models"
        case .vocabulary: "Vocabulary"
        case .replacements: "Replacements"
        case .aiActions: "AI Actions"
        case .history: "History"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "keyboard.fill"
        case .models: "waveform"
        case .vocabulary: "character.book.closed.fill"
        case .replacements: "arrow.left.arrow.right"
        case .aiActions: "sparkles"
        case .history: "clock.arrow.circlepath"
        case .permissions: "lock.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .settingsGray
        case .shortcuts: .settingsIndigo
        case .models: .settingsBlue
        case .vocabulary: .settingsYellow
        case .replacements: .settingsPink
        case .aiActions: .settingsPurple
        case .history: .settingsOrange
        case .permissions: .settingsGreen
        }
    }

    /// A run of pages under one sidebar heading.
    enum Group: CaseIterable, Identifiable {
        case dictation
        case data

        var id: Self { self }

        var title: String? {
            switch self {
            case .dictation: nil
            case .data: "Privacy"
            }
        }

        var pages: [SettingsPage] {
            switch self {
            case .dictation: [.general, .shortcuts, .models, .vocabulary, .replacements, .aiActions]
            case .data: [.history, .permissions]
            }
        }
    }
}
