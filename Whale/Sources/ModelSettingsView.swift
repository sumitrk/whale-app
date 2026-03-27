import AppKit
import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transcription model")
                        .font(.title3.bold())
                    Text("Choose which local speech model Whale should use. Install models explicitly, then switch whenever you want.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .padding(.horizontal, 18)

                TranscriptionModelGroupsView(horizontalPadding: 18, contentPadding: 18)

                if modelStore.isReady {
                    Text("The native Swift build currently exports raw Markdown transcripts. AI cleanup returns in a later release.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 18)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 18)
        .task { await modelStore.refreshNow() }
    }
}

struct TranscriptionModelGroupsView: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared
    let horizontalPadding: CGFloat
    let contentPadding: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(BuiltInModelGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title)
                        .font(.headline)
                        .padding(.horizontal, horizontalPadding)

                    VStack(spacing: 12) {
                        ForEach(BuiltInModelCatalog.models(in: group)) { model in
                            TranscriptionModelCard(model: model, contentPadding: contentPadding)
                        }
                    }
                    .padding(.horizontal, horizontalPadding)
                }
            }
        }
        .onAppear { modelStore.refresh() }
    }
}

struct TranscriptionModelCard: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    let model: BuiltInModelDescriptor
    var contentPadding: CGFloat = 16

    private var isSelected: Bool {
        settings.selectedBuiltInModelID == model.id
    }

    private var installState: NativeModelInstallState {
        modelStore.installState(for: model.id)
    }

    private var canSelect: Bool {
        modelStore.isReady(for: model.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    guard canSelect else { return }
                    settings.selectedBuiltInModelID = model.id
                } label: {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .disabled(!canSelect)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.title)
                            .font(.headline)
                        if isSelected {
                            Text("Selected")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }

                    Text(model.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(canSelect || isSelected ? 1 : 0.9)

                Spacer()

                actionView
            }

            statusView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(contentPadding)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var actionView: some View {
        switch installState {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .notInstalled:
            Button(model.actionTitle) {
                triggerPrimaryAction()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .downloading:
            Text(progressLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .ready:
            if let changeActionTitle = model.changeActionTitle {
                Button(changeActionTitle) {
                    triggerPrimaryAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                    .fontWeight(.medium)
            }
        case .failed:
            Button(model.retryActionTitle) {
                triggerPrimaryAction()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch installState {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking the local model cache…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .notInstalled:
            Text(
                canSelect
                    ? "Ready to use."
                    : "Install or validate this model before you can select it for dictation and meeting transcription."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .downloading(let progress, let phase):
            VStack(alignment: .leading, spacing: 8) {
                Text(phase)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress {
                    ProgressView(value: progress)
                        .tint(.blue)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        case .ready:
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    isSelected
                        ? readyMessage
                        : idleReadyMessage
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let localModelPath {
                    Text(localModelPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let localModelPath {
                    Text(localModelPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var progressLabel: String {
        if case .downloading(let progress, _) = installState,
           let progress {
            return "\(Int(progress * 100))%"
        }
        return "Working…"
    }

    private var localModelPath: String? {
        guard model.provisioning == .localFolder else { return nil }
        return settings.localModelPath(for: model.id)
    }

    private var readyMessage: String {
        switch model.provisioning {
        case .download:
            return "Selected and ready. New recordings will use this model."
        case .localFolder:
            return "Selected and ready. New recordings will use this local Whisper model."
        }
    }

    private var idleReadyMessage: String {
        switch model.provisioning {
        case .download:
            return "Installed and ready. Select this model whenever you want to switch."
        case .localFolder:
            return "Validated and ready. Select this model whenever you want to switch."
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

        guard panel.runModal() == .OK, let folderURL = panel.url else {
            return
        }

        modelStore.connectLocalModel(model.id, folderURL: folderURL)
    }
}
