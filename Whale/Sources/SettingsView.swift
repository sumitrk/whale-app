import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general     = "General"
    case shortcuts   = "Shortcuts"
    case model       = "Model"
    case permissions = "Permissions"
    case ai          = "AI"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:     return "gearshape"
        case .shortcuts:   return "keyboard"
        case .model:       return "cpu"
        case .permissions: return "lock.shield"
        case .ai:          return "sparkles"
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection = .general

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — plain List, no NavigationSplitView = no toolbar icon
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 160)

            Divider()

            // Detail panel
            Group {
                switch selection {
                case .general:     GeneralSettingsView()
                case .shortcuts:   ShortcutsSettingsView()
                case .model:       ModelSettingsView()
                case .permissions: PermissionsSettingsView()
                case .ai:          AISettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 620, height: 460)
    }
}
