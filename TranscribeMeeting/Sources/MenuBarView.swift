import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // Status indicator (non-interactive)
        Text(appState.statusLabel)
            .foregroundStyle(.secondary)

        Divider()

        // Start / Stop recording  (also triggered by ⌘⇧T globally)
        Button(appState.isRecording ? "Stop Recording" : "Start Recording") {
            appState.toggleMarkdown()
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!appState.isReady && !appState.isRecording)

        Divider()

        // Open last meeting if one was saved
        if let path = appState.lastMeetingPath {
            Button("Open Last Meeting") {
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
            }
        }

        Button("Open Meetings Folder") {
            NSWorkspace.shared.open(AudioRecorder.meetingsFolder())
        }

        Divider()

        Button("Settings…") {
            // TODO: Step 6 — open settings window
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit") {
            appState.server.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
