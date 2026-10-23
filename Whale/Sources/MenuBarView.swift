import SwiftUI
import Sparkle

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var accessibility: AccessibilityController
    @EnvironmentObject private var settingsCoordinator: SettingsCoordinator
    @StateObject private var updaterState: UpdaterState

    init(updater: SPUUpdater?) {
        _updaterState = StateObject(wrappedValue: UpdaterState(updater: updater))
    }

    var body: some View {
        if !accessibility.isTrusted {
            Text("Accessibility permission required.\nGlobal shortcuts and auto-paste are disabled.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            ClipboardDictationButton(capture: appState.capture) {
                appState.startClipboardOnlyDictation()
            } stop: {
                appState.stopRecording()
            }

            Button {
                openSettingsWindow(section: .permissions)
            } label: {
                Label("Open permissions", systemImage: "hand.raised.fill")
            }

            Button {
                accessibility.refresh()
            } label: {
                Label("Re-check permission", systemImage: "arrow.clockwise")
            }

            Divider()
        }

        Button {
            openSettingsWindow(section: settingsCoordinator.selection)
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button {
            openSettingsWindow(section: .history)
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
        }

        if let updater = updaterState.updater {
            Button {
                UpdateCheckAction.checkForUpdates(using: updater)
            } label: {
                Label("Check for updates", systemImage: "arrow.down.circle")
            }
            .disabled(!updaterState.canCheckForUpdates)
        }

        Divider()

        Button("Quit Whale") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
        
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                accessibility.refresh()
            }
    }

    private func openSettingsWindow(section: SettingsPage) {
        if !settingsCoordinator.focus(section: section) {
            openSettings()
        }
    }
}
