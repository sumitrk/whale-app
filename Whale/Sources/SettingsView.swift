import AppKit
import SwiftUI
import Sparkle

/// The Settings window's size limits. This is the single source of truth: `SettingsView`
/// declares them as its frame and `.windowResizability(.contentSize)` turns them into the
/// window's bounds. Nothing writes `NSWindow.minSize`/`maxSize` directly.
enum SettingsWindowMetrics {
    static let minWidth: CGFloat = 700
    static let maxWidth: CGFloat = minWidth * 1.5
    static let minHeight: CGFloat = 540
    static let maxHeight: CGFloat = 900

    /// Used only on first launch, before the window has an autosaved frame to restore.
    static let defaultWidth: CGFloat = minWidth
    static let defaultHeight: CGFloat = minHeight
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

/// Bridges the SwiftUI `Settings` scene to the window chrome SwiftUI does not expose:
/// the toolbar style, the resizable style mask, and the frame autosave name.
///
/// Size limits are deliberately *not* set here. `NSWindow.minSize`/`maxSize` and
/// `contentMinSize`/`contentMaxSize` are the same constraint in two coordinate spaces, and
/// writing them makes SwiftUI's settings window controller re-assert its own sizing — which
/// rewrites the whole style mask and drops `.resizable`, leaving the window stuck at whatever
/// size it had. The window's bounds come from `SettingsView`'s frame plus
/// `.windowResizability(.contentSize)` instead.
private struct SettingsWindowBridge: NSViewRepresentable {
    let title: String
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> SettingsWindowBridgeView {
        let view = SettingsWindowBridgeView()
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ nsView: SettingsWindowBridgeView, context: Context) {
        nsView.attachIfNeeded()
        nsView.window?.title = title
    }
}

private final class SettingsWindowBridgeView: NSView {
    var onAttach: ((NSWindow) -> Void)?
    private weak var attachedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard let window else { return }

        if attachedWindow !== window {
            attachedWindow = window
            window.setFrameAutosaveName("SettingsWindow")
            onAttach?(window)
            // SwiftUI configures the settings window after the view is attached, so chrome
            // applied now would be overwritten. Re-apply once the current turn settles.
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                Self.applyChrome(to: window)
            }
        }

        Self.applyChrome(to: window)
    }

    /// A SwiftUI `Settings` window defaults to the tall `.preference` toolbar style — centred
    /// title, centred toolbar items, and a sidebar pushed down below it — and never sets
    /// `.resizable`. Both have to be corrected here.
    ///
    /// Every write is guarded, so later view updates re-assert this for free: assigning
    /// `styleMask` or `toolbarStyle` unconditionally reconfigures the window for nothing.
    private static func applyChrome(to window: NSWindow) {
        if window.toolbarStyle != .automatic {
            window.toolbarStyle = .automatic
        }
        if window.titleVisibility != .visible {
            window.titleVisibility = .visible
        }
        if window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = false
        }
        if window.isMovableByWindowBackground {
            window.isMovableByWindowBackground = false
        }
        if !window.styleMask.contains([.resizable, .fullSizeContentView]) {
            window.styleMask.insert([.resizable, .fullSizeContentView])
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
            idealWidth: SettingsWindowMetrics.defaultWidth,
            maxWidth: SettingsWindowMetrics.maxWidth,
            minHeight: SettingsWindowMetrics.minHeight,
            idealHeight: SettingsWindowMetrics.defaultHeight,
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
            SettingsWindowBridge(title: settingsCoordinator.selection.rawValue) { window in
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
