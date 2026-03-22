import AppKit
import SwiftUI

// MARK: - PTT preset options

enum PTTPreset: String, CaseIterable, Identifiable {
    case globe    = "Globe / Fn"
    case rightCmd = "⌘ (Right)"
    case rightOpt = "⌥ (Right)"
    case rightShift = "⇧ (Right)"
    case custom   = "Custom"

    var id: String { rawValue }

    /// keyCode for the preset (nil = Custom, user picks their own)
    var keyCode: Int? {
        switch self {
        case .globe:      return 63
        case .rightCmd:   return 54
        case .rightOpt:   return 61
        case .rightShift: return 60
        case .custom:     return nil
        }
    }
}

// MARK: - View

struct ShortcutsSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    /// Tracks the picker selection independently so selecting Custom isn't
    /// immediately overridden by the computed value.
    @State private var pttPreset: PTTPreset = .globe
    /// True only right after the user picks Custom — auto-starts the recorder.
    @State private var pttRecorderAutoStart = false

    private func derivedPreset() -> PTTPreset {
        guard store.pttModifiers == 0 else { return .custom }
        return PTTPreset.allCases.first { $0.keyCode == store.pttKeyCode } ?? .custom
    }

    var body: some View {
        Form {
            // MARK: Push-to-Talk
            Section {
                LabeledContent("Key") {
                    Picker("", selection: $pttPreset) {
                        ForEach(PTTPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: pttPreset) { preset in
                        if let kc = preset.keyCode {
                            store.pttKeyCode = kc
                            store.pttModifiers = 0
                        } else {
                            // Custom selected — auto-start the recorder
                            pttRecorderAutoStart = true
                        }
                    }
                }

                if pttPreset == .custom {
                    LabeledContent("Custom key") {
                        PTTRecorderView(
                            keyCode:        $store.pttKeyCode,
                            modifiers:      $store.pttModifiers,
                            startImmediately: pttRecorderAutoStart
                        )
                        .onAppear { pttRecorderAutoStart = false }
                    }
                }
            } header: {
                Text("Push-to-Talk")
            } footer: {
                Text("Hold \(store.pttKeyLabel) to record. Release to transcribe and paste.")
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
                    HStack(spacing: 6) {
                        Text(store.transcriptFolder.abbreviatedPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button { pickFolder() } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Toggle Record  (saves transcript as markdown)")
            } footer: {
                Text("Press \(store.toggleKeyLabel) to start, press again to stop and save.")
            }
        }
        .formStyle(.grouped)
        .onAppear { pttPreset = derivedPreset() }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder where transcripts will be saved."
        if panel.runModal() == .OK, let url = panel.url {
            store.transcriptFolderPath = url.path
        }
    }
}

// MARK: - KeyBadge

struct KeyBadge: View {
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

extension URL {
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
