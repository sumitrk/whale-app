import SwiftUI
import Sparkle

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The bundle launches as a regular app so Launch Services carries the user's
        // activation intent into first-run onboarding. Returning launches become a
        // menu-bar app before launch finishes, avoiding a Dock icon or app menu.
        guard SettingsStore.shared.hasCompletedOnboarding else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TranscribeMeetingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    @StateObject private var accessibilityController: AccessibilityController
    @StateObject private var settingsCoordinator: SettingsCoordinator
    private let updaterController: SPUStandardUpdaterController?

    init() {
        let accessibilityController = AccessibilityController()
        let settingsCoordinator = SettingsCoordinator()
        _accessibilityController = StateObject(wrappedValue: accessibilityController)
        _settingsCoordinator = StateObject(wrappedValue: settingsCoordinator)
        _appState = StateObject(
            wrappedValue: AppState(
                accessibility: accessibilityController
            )
        )
        if AppRuntimeInfo.current.sparkleDisabled {
            updaterController = nil
        } else {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
    }

    private var menuBarIconName: String {
        if appState.isRecording {
            return "record.circle.fill"
        }
        if !accessibilityController.isTrusted {
            return "exclamationmark.triangle.fill"
        }
        return "mic"
    }

    var body: some Scene {
        MenuBarExtra("Whale", systemImage: menuBarIconName) {
            MenuBarView(updater: updaterController?.updater)
                .environmentObject(appState)
                .environmentObject(accessibilityController)
                .environmentObject(settingsCoordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(updater: updaterController?.updater)
                .environmentObject(appState)
                .environmentObject(accessibilityController)
                .environmentObject(settingsCoordinator)
        }
        .defaultSize(width: SettingsWindowMetrics.defaultWidth, height: SettingsWindowMetrics.defaultHeight)
        .windowResizability(.contentSize)
    }
}
