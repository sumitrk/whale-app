import SwiftUI
import Sparkle

/// The Settings window's size limits. This is the single source of truth: `SettingsView`
/// declares them as its frame and `.windowResizability(.contentSize)` turns them into the
/// window's bounds. Nothing writes `NSWindow.minSize`/`maxSize` directly.
enum SettingsWindowMetrics {
    static let minWidth: CGFloat = 720
    static let maxWidth: CGFloat = minWidth * 1.5
    static let minHeight: CGFloat = 540
    static let maxHeight: CGFloat = 900

    /// Used only on first launch, before the window has an autosaved frame to restore.
    static let defaultWidth: CGFloat = minWidth
    static let defaultHeight: CGFloat = minHeight
}

/// Settings: a sidebar of pages and the chosen page beside it, laid out like Spark's.
struct SettingsView: View {
    static let sidebarWidth: CGFloat = 200

    @EnvironmentObject private var settingsCoordinator: SettingsCoordinator

    let updater: SPUUpdater?

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $settingsCoordinator.selection)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            SettingsPageView(page: settingsCoordinator.selection, updater: updater)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.primary.opacity(0.03).ignoresSafeArea())
                .windowToolbarBackgroundHidden()
                .topScrollEdgeEffectHidden()
        }
        .toolbar(removing: .sidebarToggle)
        .windowTitleRemoved()
        .frame(
            minWidth: SettingsWindowMetrics.minWidth,
            idealWidth: SettingsWindowMetrics.defaultWidth,
            maxWidth: SettingsWindowMetrics.maxWidth,
            minHeight: SettingsWindowMetrics.minHeight,
            idealHeight: SettingsWindowMetrics.defaultHeight,
            maxHeight: SettingsWindowMetrics.maxHeight
        )
        .background(SettingsWindowConfigurator(onAttach: settingsCoordinator.registerSettingsWindow))
    }
}
