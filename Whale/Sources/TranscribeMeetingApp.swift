import SwiftUI
import Sparkle

@main
struct TranscribeMeetingApp: App {
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
