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

    // AppKit uses points; converting keeps the requested offset at 8 physical pixels.
    static let trafficLightOffsetPixels: CGFloat = 8
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
    private var baseOrigins: [ObjectIdentifier: NSPoint] = [:]

    func style(_ window: NSWindow?) {
        guard let window else { return }

        if self.window !== window {
            self.window = window
            baseOrigins.removeAll()
        }

        removeSidebarToggle(from: window)
        hideSidebarToggle(in: window.contentView)
        preventSidebarCollapse(in: window.contentViewController)

        let offset = SettingsWindowMetrics.trafficLightOffsetPixels / window.backingScaleFactor
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        for buttonType in buttonTypes {
            guard let button = window.standardWindowButton(buttonType) else { continue }

            let key = ObjectIdentifier(button)
            let baseOrigin = baseOrigins[key] ?? button.frame.origin
            baseOrigins[key] = baseOrigin
            button.setFrameOrigin(
                NSPoint(x: baseOrigin.x - offset, y: baseOrigin.y - offset)
            )
        }
    }

    private func removeSidebarToggle(from window: NSWindow) {
        guard let toolbar = window.toolbar else { return }

        for index in toolbar.items.indices.reversed() {
            let item = toolbar.items[index]
            let identifier = item.itemIdentifier.rawValue.lowercased()
            let label = item.label.lowercased()
            let imageName = item.image?.name()?.lowercased() ?? ""

            if identifier.contains("sidebar") || label.contains("sidebar") || imageName.contains("sidebar") {
                toolbar.removeItem(at: index)
            }
        }
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
                    .navigationTitle(settingsCoordinator.selection.rawValue)
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
