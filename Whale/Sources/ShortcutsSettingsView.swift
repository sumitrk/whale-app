import AppKit
import SwiftUI

// MARK: - PTT preset options

enum PTTPreset: String, CaseIterable, Identifiable {
    case globe    = "Globe / Fn"
    case leftControl = "⌃ (Left)"
    case rightCmd = "⌘ (Right)"
    case rightOpt = "⌥ (Right)"
    case rightShift = "⇧ (Right)"
    case custom   = "Custom"

    var id: String { rawValue }

    /// keyCode for the preset (nil = Custom, user picks their own)
    var keyCode: Int? {
        switch self {
        case .globe:      return 63
        case .leftControl: return 59
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
    @State private var actionPreset: PTTPreset = .leftControl
    @State private var actionRecorderAutoStart = false

    private func derivedPreset() -> PTTPreset {
        guard store.pttModifiers == 0 else { return .custom }
        return PTTPreset.allCases.first { $0.keyCode == store.pttKeyCode } ?? .custom
    }

    private func derivedActionPreset() -> PTTPreset {
        guard store.aiActionModifiers == 0 else { return .custom }
        return PTTPreset.allCases.first { $0.keyCode == store.aiActionKeyCode } ?? .custom
    }

    var body: some View {
        Form {
            // MARK: Push-to-Talk
            Section {
                Picker("Key", selection: $pttPreset) {
                    ForEach(PTTPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: pttPreset) { _, preset in
                    if let kc = preset.keyCode {
                        store.pttKeyCode = kc
                        store.pttModifiers = 0
                    } else {
                        // Custom selected — auto-start the recorder
                        pttRecorderAutoStart = true
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

            Section {
                Picker("Key", selection: $actionPreset) {
                    ForEach(PTTPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: actionPreset) { _, preset in
                    if let keyCode = preset.keyCode {
                        store.aiActionKeyCode = keyCode
                        store.aiActionModifiers = 0
                    } else {
                        actionRecorderAutoStart = true
                    }
                }
                if actionPreset == .custom {
                    LabeledContent("Custom key") {
                        PTTRecorderView(
                            keyCode: $store.aiActionKeyCode,
                            modifiers: $store.aiActionModifiers,
                            startImmediately: actionRecorderAutoStart
                        )
                        .onAppear { actionRecorderAutoStart = false }
                    }
                }
            } header: {
                Text("AI Action")
            } footer: {
                Text("Hold \(store.aiActionKeyLabel) to speak an instruction. Press another key or mouse button while holding a modifier-only shortcut to cancel it.")
            }

            // MARK: Transcript Mode
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
                        .accessibilityLabel("Choose transcript folder")
                    }
                }
            } header: {
                Text("Transcript Mode")
            } footer: {
                Text("Press \(store.toggleKeyLabel) to start, press again to stop and save the transcript as Markdown.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            pttPreset = derivedPreset()
            actionPreset = derivedActionPreset()
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder where transcripts will be saved."
        if panel.runModal() == .OK, let url = panel.url {
            store.setTranscriptFolderURL(url)
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
                    .fill(.quaternary)
                    .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
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
