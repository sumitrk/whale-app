import AppKit
import SwiftUI
import Sparkle

private enum SettingsWindowMetrics {
    static let minWidth: CGFloat = 720
    static let idealWidth: CGFloat = 860
    static let maxWidth: CGFloat = 1120
    static let minHeight: CGFloat = 520
    static let idealHeight: CGFloat = 620
    static let maxHeight: CGFloat = 820

    // Native NavigationSplitView keeps this divider resizable.
    // Change these fractions to resize the Settings navigation pane.
    static let sidebarMinFraction: CGFloat = 0.18
    static let sidebarMaxFraction: CGFloat = 0.30
    static let sidebarIdealFraction: CGFloat =
        sidebarMinFraction + (sidebarMaxFraction - sidebarMinFraction) * 0.5
}

private struct SettingsWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeCoordinator() -> TrafficLightPositioner {
        TrafficLightPositioner()
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

private final class TrafficLightPositioner {
    private weak var window: NSWindow?

    func style(_ window: NSWindow?) {
        guard let window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert([.resizable, .fullSizeContentView])
        // Dropping the toolbar entirely (rather than just hiding its sidebar-toggle
        // item) removes the reserved title-bar strip, so the traffic lights sit
        // directly over the sidebar and the native full-size-content safe area lines
        // the sidebar list up right underneath them.
        window.toolbar = nil

        if self.window !== window {
            self.window = window
        }

        hideSidebarToggle(in: window.contentView)
        preventSidebarCollapse(in: window.contentViewController)
    }

    private func hideSidebarToggle(in view: NSView?) {
        guard let view else { return }

        if let button = view as? NSButton {
            let identifier = button.identifier?.rawValue.lowercased() ?? ""
            let title = button.title.lowercased()
            let toolTip = button.toolTip?.lowercased() ?? ""
            let imageName = button.image?.name()?.lowercased() ?? ""

            if identifier.contains("sidebar") || title.contains("sidebar") ||
                toolTip.contains("sidebar") || imageName.contains("sidebar") {
                button.isHidden = true
                button.isEnabled = false
            }
        }

        for subview in view.subviews {
            hideSidebarToggle(in: subview)
        }
    }

    private func preventSidebarCollapse(in viewController: NSViewController?) {
        guard let viewController else { return }

        if let splitViewController = viewController as? NSSplitViewController,
           let sidebarItem = splitViewController.splitViewItems.first {
            sidebarItem.canCollapse = false
            sidebarItem.isCollapsed = false
        }

        for child in viewController.children {
            preventSidebarCollapse(in: child)
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
        GeometryReader { geometry in
            NavigationSplitView {
                List(SettingsSection.allCases, selection: sidebarSelection) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(
                    min: geometry.size.width * SettingsWindowMetrics.sidebarMinFraction,
                    ideal: geometry.size.width * SettingsWindowMetrics.sidebarIdealFraction,
                    max: geometry.size.width * SettingsWindowMetrics.sidebarMaxFraction
                )
                .toolbar(removing: .sidebarToggle)
            } detail: {
                selectedSettingsView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .navigationSplitViewStyle(.balanced)
            .toolbar(removing: .sidebarToggle)
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
