import SwiftUI
import Sparkle

private enum SettingsWindowMetrics {
    static let minWidth: CGFloat = 720
    static let idealWidth: CGFloat = 860
    static let maxWidth: CGFloat = 1120
    static let minHeight: CGFloat = 520
    static let idealHeight: CGFloat = 620
    static let maxHeight: CGFloat = 820
}

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
    case general       = "General"
    case shortcuts     = "Shortcuts"
    case transcription = "Transcription"
    case aiActions     = "AI Actions"
    case history       = "History"
    case permissions   = "Permissions"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general:       return "gearshape"
        case .shortcuts:     return "keyboard"
        case .transcription: return "waveform"
        case .aiActions:     return "sparkles"
        case .history:       return "clock.arrow.circlepath"
        case .permissions:   return "lock.shield"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settingsCoordinator: SettingsCoordinator
    let updater: SPUUpdater?

    private var sidebarSelection: Binding<SettingsSection?> {
        Binding(
            get: { settingsCoordinator.selection },
            set: { selection in
                if let selection {
                    settingsCoordinator.selection = selection
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: sidebarSelection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 175, ideal: 200, max: 230)
        } detail: {
            Group {
                switch settingsCoordinator.selection {
                case .general:       GeneralSettingsView(updater: updater)
                case .shortcuts:     ShortcutsSettingsView()
                case .transcription: TranscriptionSettingsView()
                case .aiActions:     AIActionSettingsView()
                case .history:       HistoryView()
                case .permissions:   PermissionsSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(settingsCoordinator.selection.rawValue)
        }
        .frame(
            minWidth: SettingsWindowMetrics.minWidth,
            idealWidth: SettingsWindowMetrics.idealWidth,
            maxWidth: SettingsWindowMetrics.maxWidth,
            minHeight: SettingsWindowMetrics.minHeight,
            idealHeight: SettingsWindowMetrics.idealHeight,
            maxHeight: SettingsWindowMetrics.maxHeight
        )
        .background(
            SettingsWindowAccessor { window in
                settingsCoordinator.registerSettingsWindow(window)
            }
        )
    }
}
