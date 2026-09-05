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
            Text("Accessibility permission required.\nGlobal shortcuts and auto-paste are disabled.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            if appState.isRecording {
                Button {
                    Task { await appState.stopRecording() }
                } label: {
                    Label("Stop Dictation", systemImage: "stop.fill")
                }
            } else {
                Button {
                    appState.startClipboardOnlyDictation()
                } label: {
                    Label("Start Dictation (Clipboard Only)", systemImage: "mic.fill")
                }
            }

            Button {
                openSettingsWindow(section: .permissions)
            } label: {
                Label("Open Permissions", systemImage: "hand.raised.fill")
            }

            Button {
                accessibility.refresh()
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }

            Divider()
        }

        if let updater {
            Button {
                updater.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
            .disabled(!updater.canCheckForUpdates)

            Divider()
        }

        Button {
            openSettingsWindow(section: settingsCoordinator.selection)
        } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button {
            openSettingsWindow(section: .history)
        } label: {
            Label("History…", systemImage: "clock.arrow.circlepath")
        }

        Button {
            DiagnosticLog.openInFinder()
        } label: {
            Label("View Log", systemImage: "doc.text.magnifyingglass")
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
