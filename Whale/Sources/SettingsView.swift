import AppKit
import SwiftUI
import Sparkle

enum SettingsWindowMetrics {
    static let minWidth: CGFloat = 700
    static let idealWidth: CGFloat = minWidth
    static let maxWidth: CGFloat = minWidth * 1.5
    static let minHeight: CGFloat = 540
    static let idealHeight: CGFloat = minHeight
    static let maxHeight: CGFloat = 900
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

private enum SettingsAppVersion {
    static let displayString: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "Version \(version) (\(build))"
    }()
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    let title: String
    let onResolve: (NSWindow?) -> Void

    func makeCoordinator() -> SettingsWindowStyler {
        SettingsWindowStyler()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.style(view.window, title: title)
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.style(nsView.window, title: title)
            onResolve(nsView.window)
        }
    }
}

private final class SettingsWindowStyler {
    private weak var window: NSWindow?

    func style(_ window: NSWindow?, title: String) {
        guard let window else { return }

        window.title = title
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .automatic
        window.styleMask.insert([.resizable, .fullSizeContentView])
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: SettingsWindowMetrics.minWidth, height: SettingsWindowMetrics.minHeight)
        window.maxSize = NSSize(width: SettingsWindowMetrics.maxWidth, height: SettingsWindowMetrics.maxHeight)

        if self.window !== window {
            self.window = window
            window.setFrameAutosaveName("SettingsWindow")
        }

        var frame = window.frame
        frame.size.width = min(max(frame.size.width, SettingsWindowMetrics.minWidth), SettingsWindowMetrics.maxWidth)
        frame.size.height = min(max(frame.size.height, SettingsWindowMetrics.minHeight), SettingsWindowMetrics.maxHeight)
        if frame.size != window.frame.size {
            window.setFrame(frame, display: true)
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
                .navigationSplitViewColumnWidth(min: 360, ideal: 500, max: SettingsWindowMetrics.maxWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsWindowMetrics.minWidth,
            idealWidth: SettingsWindowMetrics.idealWidth,
            maxWidth: SettingsWindowMetrics.maxWidth,
            minHeight: SettingsWindowMetrics.minHeight,
            idealHeight: SettingsWindowMetrics.idealHeight,
            maxHeight: SettingsWindowMetrics.maxHeight
        )
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
            SettingsWindowAccessor(title: settingsCoordinator.selection.rawValue) { window in
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
    }
}
