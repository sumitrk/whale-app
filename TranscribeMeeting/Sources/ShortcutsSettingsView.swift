import SwiftUI

struct ShortcutsSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var showingFolderPicker = false

    var body: some View {
        Form {
            // MARK: Push-to-Talk
            Section {
                LabeledContent("Key") {
                    HStack(spacing: 6) {
                        KeyBadge("Globe")
                        KeyBadge("Fn")
                        Text("(fixed)")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Push-to-Talk")
            } footer: {
                Text("Hold the Globe/Fn key to record. Release to transcribe and paste.")
            }

            // MARK: Toggle Record
            Section {
                LabeledContent("Key") {
                    KeyRecorderView(
                        keyCode:   $store.toggleKeyCode,
                        modifiers: $store.toggleModifiers
                    )
                }

                LabeledContent("Save transcripts to") {
                    HStack {
                        Text(store.transcriptFolder.abbreviatedPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { showingFolderPicker = true }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Toggle Record  (saves transcript as markdown)")
            } footer: {
                Text("Press ⌘⇧T to start, press again to stop and save.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                store.transcriptFolderPath = url.path
            }
        }
    }
}

// MARK: - KeyBadge

private struct KeyBadge: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
    }
}

// MARK: - URL helper

private extension URL {
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
