import AppKit
import SwiftUI

struct ModelsSettingsView: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared

    var body: some View {
        Form {
            ModelListSections()
            SmartFormattingSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .task { await modelStore.refreshNow() }
    }
}

/// The model list itself, without a `Form` around it, so the settings pane and the
/// onboarding step present exactly the same rows.
///
/// Two boxes rather than one: the models Whale ships and installs itself, then the
/// bring-your-own folder under its own header.
struct ModelListSections: View {
    var body: some View {
        Section {
            ForEach(BuiltInModelCatalog.models(from: .bundled)) { model in
                ModelRow(model: model)
            }
        }

        Section {
            ForEach(BuiltInModelCatalog.models(from: .custom)) { model in
                ModelRow(model: model)
            }
        } header: {
            Text("Custom")
        } footer: {
            Text("All models run locally on your Mac. Audio never leaves the device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Post-transcription rewriting, kept out of `ModelListSections` so the onboarding
/// step stays a plain model picker.
private struct SmartFormattingSection: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Section {
            Toggle(isOn: $settings.smartFormattingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Formatting")
                    Text("Write spoken numbers, money, dates, and times the way you would type them — “twenty one dollars and fifty cents” becomes “$21.50”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        } header: {
            Text("Formatting")
        }
    }
}

/// One model in the list. The row *is* the picker: clicking an installed row makes it the
/// active model, which is why there is no separate "Active Model" dropdown above the list.
private struct ModelRow: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isHovering = false

    let model: BuiltInModelDescriptor

    private var rowModel: TranscriptionModelRowModel {
        TranscriptionModelRowModel(
            model: model,
            installState: modelStore.installState(for: model.id),
            isSelected: settings.selectedBuiltInModelID == model.id
        )
    }

    var body: some View {
        let row = rowModel

        HStack(alignment: .center, spacing: 10) {
            ModelIcon(model: model)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)

                HStack(spacing: 5) {
                    if row.status.showsDot {
                        Circle()
                            .fill(dotColor(for: row.status))
                            .frame(width: 7, height: 7)
                    }

                    Text(statusLine(for: row))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let errorText = row.errorText {
                    Text(errorText)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            accessory(for: row)
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering && row.isReady ? 0.06 : 0))
                .padding(.horizontal, -6)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { activate(row) }
        .contextMenu { contextMenu(for: row) }
    }

    /// While a download or check is running the phase text is the whole story; the language
    /// only earns its place next to a settled status.
    private func statusLine(for row: TranscriptionModelRowModel) -> String {
        if case .working = row.status {
            return row.statusText
        }
        return "\(row.statusText) · \(model.languageLabel)"
    }

    private func dotColor(for status: TranscriptionModelStatus) -> Color {
        switch status {
        case .active:                   return .green
        case .needsAttention:           return .red
        case .inactive, .notInstalled:  return .secondary.opacity(0.5)
        case .working:                  return .clear
        }
    }

    @ViewBuilder
    private func accessory(for row: TranscriptionModelRowModel) -> some View {
        if row.isBusy {
            ProgressView()
                .controlSize(.small)
        } else if let title = row.primaryActionTitle {
            // Deliberately not `.borderedProminent`: nothing on this pane is the one thing
            // the user came here to do, so no row gets to claim the screen's default action.
            Button(title) { triggerPrimaryAction() }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func contextMenu(for row: TranscriptionModelRowModel) -> some View {
        if let path = localModelPath {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .disabled(!FileManager.default.fileExists(atPath: path))

            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }

        if let resetActionTitle = row.resetActionTitle {
            Divider()
            Button(resetActionTitle) { modelStore.reset(model.id) }
        }
    }

    private func activate(_ row: TranscriptionModelRowModel) {
        guard row.isReady else { return }
        settings.selectedBuiltInModelID = model.id
    }

    private var localModelPath: String? {
        switch model.id {
        case .parakeetEnglishV2:
            return AppRuntimeInfo.current.parakeetEnglishV2DirectoryURL.path
        case .whisperLargeV3Turbo, .whisperLocalFolder:
            return settings.localModelPath(for: model.id)
        }
    }

    private func triggerPrimaryAction() {
        switch model.provisioning {
        case .download:
            modelStore.install(model.id)
        case .localFolder:
            chooseLocalFolder()
        }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose Folder"
        panel.message = "Select a WhisperKit/Core ML folder that contains MelSpectrogram, AudioEncoder, and TextDecoder."

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        modelStore.connectLocalModel(model.id, folderURL: folderURL)
    }
}

/// The mark is derived from where a model comes from, never assigned per model: every
/// Parakeet checkpoint is the blue waveform, every Whisper checkpoint the purple bubble,
/// and anything the user supplied themselves is the orange folder whatever loads it.
///
/// So adding a model to a family the app already speaks costs nothing here, and adding a
/// whole new engine fails to compile until someone picks its mark on purpose.
private struct ModelIcon: View {
    let model: BuiltInModelDescriptor

    private var appearance: (color: Color, symbol: String) {
        // A folder the user pointed at is identified by that fact, not by the engine that
        // happens to read it — otherwise it would be indistinguishable from bundled Whisper.
        guard model.source != .custom else {
            return (.orange, "folder.fill")
        }

        switch model.group {
        case .parakeet: return (.blue, "waveform")
        case .whisper:  return (.purple, "text.bubble.fill")
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(appearance.color)
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: appearance.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}
