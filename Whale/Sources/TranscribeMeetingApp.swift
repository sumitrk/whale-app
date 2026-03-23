import SwiftUI
import Sparkle

@main
struct TranscribeMeetingApp: App {
    @StateObject private var appState = AppState()
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(updater: updaterController.updater)
                .environmentObject(appState)
        } label: {
            let icon = appState.isRecording ? "record.circle.fill" : "mic"
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}
