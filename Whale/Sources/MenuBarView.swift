import SwiftUI
import Sparkle

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject var appState: AppState
    @EnvironmentObject private var accessibility: AccessibilityController
    @EnvironmentObject private var settingsCoordinator: SettingsCoordinator
    let updater: SPUUpdater?

    var body: some View {
        if !accessibility.isTrusted {
            Text("Accessibility permission required. Global shortcuts and auto-paste are disabled.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            if appState.isRecording {
                Button("Stop Dictation") {
                    Task { await appState.stopRecording() }
                }
            } else {
                Button("Start Dictation (Clipboard Only)") {
                    appState.startClipboardOnlyDictation()
                }
            }

            Button("Open Permissions") {
                openSettingsWindow(section: .permissions)
            }

            Button("Re-check") {
                accessibility.refresh()
            }

            Divider()
        }

        if let updater {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Divider()
        }

        Button("Settings…") {
            openSettingsWindow(section: settingsCoordinator.selection)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("View Log") {
            DiagnosticLog.openInFinder()
        }

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
        
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                accessibility.refresh()
            }
    }

    private func openSettingsWindow(section: SettingsSection) {
        if !settingsCoordinator.focus(section: section) {
            openSettings()
        }
    }
}
