import Sparkle
import SwiftUI

/// The chosen Settings page.
struct SettingsPageView: View {
    let page: SettingsPage
    let updater: SPUUpdater?

    var body: some View {
        switch page {
        case .general: GeneralSettingsView(updater: updater)
        case .shortcuts: ShortcutsSettingsView()
        case .models: ModelsSettingsView()
        case .vocabulary: VocabularySettingsView()
        case .replacements: ReplacementsSettingsView()
        case .aiActions: AIActionSettingsView()
        case .history: HistoryView()
        case .permissions: PermissionsSettingsView()
        }
    }
}
