import SwiftUI

private struct SettingsWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general     = "General"
    case shortcuts   = "Shortcuts"
    case model       = "Model"
    case permissions = "Permissions"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:     return "gearshape"
        case .shortcuts:   return "keyboard"
        case .model:       return "cpu"
        case .permissions: return "lock.shield"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settingsCoordinator: SettingsCoordinator

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — plain List, no NavigationSplitView = no toolbar icon
            List(SettingsSection.allCases, selection: $settingsCoordinator.selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 160)

            Divider()

            // Detail panel
            Group {
                switch settingsCoordinator.selection {
                case .general:     GeneralSettingsView()
                case .shortcuts:   ShortcutsSettingsView()
                case .model:       ModelSettingsView()
                case .permissions: PermissionsSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 620, height: 460)
        .background(
            SettingsWindowAccessor { window in
                settingsCoordinator.registerSettingsWindow(window)
            }
        )
    }
}
