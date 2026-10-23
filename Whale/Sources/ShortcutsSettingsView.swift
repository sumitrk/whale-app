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

    private var keyChoices: [CapsuleChoice<PTTPreset>] {
        PTTPreset.allCases.map { .option($0.rawValue, $0) }
    }

    private var dictationFooter: LocalizedStringKey {
        switch store.dictationKeyMode {
        case .hold: "Hold \(store.pttKeyLabel) to record. Release to transcribe and paste."
        case .toggle: "Press \(store.pttKeyLabel) to record. Press it again to transcribe and paste."
        }
    }

    var body: some View {
        SettingsPageLayout(title: "Shortcuts") {
            SettingsSection("Dictation", footer: dictationFooter) {
                SettingsPickerRow(
                    "Key",
                    icon: SettingsRowIcon("mic.fill", .settingsBlue),
                    selection: $pttPreset,
                    choices: keyChoices
                )
                SettingsPickerRow(
                    "Mode",
                    icon: SettingsRowIcon("hand.tap.fill", .settingsTeal),
                    selection: $store.dictationKeyMode,
                    choices: DictationKeyMode.allCases.map { .option($0.title, $0) }
                )
                if pttPreset == .custom {
                    SettingsRow("Custom key") {
                        PTTRecorderView(
                            keyCode: $store.pttKeyCode,
                            modifiers: $store.pttModifiers,
                            startImmediately: pttRecorderAutoStart
                        )
                        .onAppear { pttRecorderAutoStart = false }
                    }
                }
            }

            SettingsSection(
                "AI action",
                footer: "Hold \(store.aiActionKeyLabel) to speak an instruction. Press another key or mouse button while holding a modifier-only shortcut to cancel it."
            ) {
                SettingsPickerRow(
                    "Key",
                    icon: SettingsRowIcon("sparkles", .settingsPurple),
                    selection: $actionPreset,
                    choices: keyChoices
                )
                if actionPreset == .custom {
                    SettingsRow("Custom key") {
                        PTTRecorderView(
                            keyCode: $store.aiActionKeyCode,
                            modifiers: $store.aiActionModifiers,
                            startImmediately: actionRecorderAutoStart
                        )
                        .onAppear { actionRecorderAutoStart = false }
                    }
                }
            }

            SettingsSection(
                "Transcript mode",
                footer: "Press \(store.toggleKeyLabel) to start, press again to stop and save the transcript as Markdown."
            ) {
                SettingsRow("Key", icon: SettingsRowIcon("doc.text.fill", .settingsOrange)) {
                    KeyRecorderView(keyCode: $store.toggleKeyCode, modifiers: $store.toggleModifiers)
                }
                SettingsRow("Save transcripts to", icon: SettingsRowIcon("folder.fill", .settingsCyan)) {
                    // Verbatim: a folder name is not Markdown.
                    Text(verbatim: store.transcriptFolder.abbreviatedPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                    Button("Choose…", action: pickFolder)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
        }
        .onAppear {
            pttPreset = derivedPreset()
            actionPreset = derivedActionPreset()
        }
        .onChange(of: pttPreset) { _, preset in
            if let keyCode = preset.keyCode {
                store.pttKeyCode = keyCode
                store.pttModifiers = 0
            } else {
                // Custom selected — auto-start the recorder
                pttRecorderAutoStart = true
            }
        }
        .onChange(of: actionPreset) { _, preset in
            if let keyCode = preset.keyCode {
                store.aiActionKeyCode = keyCode
                store.aiActionModifiers = 0
            } else {
                actionRecorderAutoStart = true
            }
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
