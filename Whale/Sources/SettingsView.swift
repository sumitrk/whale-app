import AppKit
import SwiftUI
import Sparkle

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

private enum SettingsAppVersion {
    static let displayString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }()
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeCoordinator() -> SettingsWindowStyler {
        SettingsWindowStyler()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.style(view.window)
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.style(nsView.window)
            onResolve(nsView.window)
        }
    }
}

private final class SettingsWindowStyler {
    private weak var window: NSWindow?

    func style(_ window: NSWindow?) {
        guard let window else { return }

        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .automatic
        window.styleMask.insert([.resizable, .fullSizeContentView])
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 620, height: 460)

        if self.window !== window {
            self.window = window
            window.setFrameAutosaveName("SettingsWindow")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settingsCoordinator: SettingsCoordinator
    @State private var navigationHistory: [SettingsSection] = [.general]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

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
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebarView(selection: sidebarSelection)
                .frame(width: 200)
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            selectedSettingsView
                .navigationTitle(settingsCoordinator.selection.rawValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 540)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    goBack()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoBack)
                .help("Back")

                Button {
                    goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoForward)
                .help("Forward")
            }
        }
        .background(
            SettingsWindowAccessor { window in
                settingsCoordinator.registerSettingsWindow(window)
            }
        )
        .onChange(of: settingsCoordinator.selection) { _, _ in
            recordNavigation()
        }
    }

    private var canGoBack: Bool {
        historyIndex > 0
    }

    private var canGoForward: Bool {
        historyIndex < navigationHistory.count - 1
    }

    private func goBack() {
        guard canGoBack else { return }
        isHistoryNavigation = true
        historyIndex -= 1
        settingsCoordinator.selection = navigationHistory[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func goForward() {
        guard canGoForward else { return }
        isHistoryNavigation = true
        historyIndex += 1
        settingsCoordinator.selection = navigationHistory[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func recordNavigation() {
        guard !isHistoryNavigation else { return }
        let section = settingsCoordinator.selection
        guard navigationHistory.last != section else { return }

        if historyIndex < navigationHistory.count - 1 {
            navigationHistory = Array(navigationHistory.prefix(historyIndex + 1))
        }

        navigationHistory.append(section)
        historyIndex = navigationHistory.count - 1
    }

    @ViewBuilder
    private var selectedSettingsView: some View {
        switch settingsCoordinator.selection {
        case .general:       GeneralSettingsView(updater: updater)
        case .shortcuts:     ShortcutsSettingsView()
        case .transcription: TranscriptionSettingsView()
        case .aiActions:     AIActionSettingsView()
        case .history:       HistoryView()
        case .permissions:   PermissionsSettingsView()
        }
    }
}

private struct SettingsSidebarView: View {
    @Binding var selection: SettingsSection?

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsSection.allCases) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .foregroundStyle(.primary)
                    .tag(section)
            }

            Text(SettingsAppVersion.displayString)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fontDesign(.monospaced)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
    }
}
