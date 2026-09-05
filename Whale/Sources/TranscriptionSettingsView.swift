import AppKit
import SwiftUI

struct TranscriptionSettingsView: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared

    var body: some View {
        Form {
            TranscriptionActiveModelSection()
            TranscriptionModelManagementSections()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .task { await modelStore.refreshNow() }
    }
}

struct TranscriptionActiveModelSection: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    private var readyModels: [BuiltInModelDescriptor] {
        BuiltInModelCatalog.allModels.filter { modelStore.isReady(for: $0.id) }
    }

    var body: some View {
        Section("Active Model") {
            if readyModels.isEmpty {
                Text("Install or connect a model below before choosing the active transcription model.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: $settings.selectedBuiltInModelID) {
                    ForEach(readyModels) { model in
                        Text(model.title).tag(model.id)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }
}

struct TranscriptionModelManagementSections: View {
    var body: some View {
        ForEach(BuiltInModelGroup.allCases) { group in
            Section(group.title) {
                ForEach(BuiltInModelCatalog.models(in: group)) { model in
                    TranscriptionModelRow(model: model)
                }
            }
        }
    }
}

private struct TranscriptionModelRow: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    let model: BuiltInModelDescriptor

    private var isSelected: Bool {
        settings.selectedBuiltInModelID == model.id
    }

    private var installState: NativeModelInstallState {
        modelStore.installState(for: model.id)
    }

    private var rowModel: TranscriptionModelRowModel {
        TranscriptionModelRowModel(
            model: model,
            installState: installState,
            isSelected: isSelected
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                TranscriptionModelThumbnail(modelID: model.id)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model.title)
                            .font(.headline)

                        if isSelected && rowModel.isReady {
                            Label("Active", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(model.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)
                actionView
            }

            statusView
                .padding(.leading, 68)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var actionView: some View {
        if case .checking = installState {
            ProgressView()
                .controlSize(.small)
        } else if case .downloading(let progress, _) = installState {
            Text(progress.map { "\(Int($0 * 100))%" } ?? "Working…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else if let title = rowModel.primaryActionTitle {
            if rowModel.isReady {
                Button(title) {
                    triggerPrimaryAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button(title) {
                    triggerPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } else if rowModel.isReady {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(rowModel.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if rowModel.showsProgress {
                if let progress = rowModel.progress {
                    ProgressView(value: progress)
                } else if case .downloading = installState {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let errorText = rowModel.errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let localModelPath, rowModel.isReady || rowModel.errorText != nil {
                Text(localModelPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let resetActionTitle = rowModel.resetActionTitle {
                Button(resetActionTitle) {
                    modelStore.reset(model.id)
                }
                .buttonStyle(.link)
            }
        }
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

private struct TranscriptionModelThumbnail: View {
    let modelID: BuiltInModelID

    private var colors: [Color] {
        switch modelID {
        case .parakeetEnglishV2:
            return [.cyan, .blue]
        case .whisperLargeV3Turbo:
            return [.indigo, .purple]
        case .whisperLocalFolder:
            return [.orange, .pink]
        }
    }

    private var symbolName: String {
        switch modelID {
        case .parakeetEnglishV2:
            return "waveform"
        case .whisperLargeV3Turbo:
            return "text.bubble.fill"
        case .whisperLocalFolder:
            return "folder.fill"
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: colors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.55), lineWidth: 1)

            Image(systemName: symbolName)
                .font(.system(size: 23, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)

            if modelID == .whisperLocalFolder {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.2), in: Circle())
                    .offset(x: 18, y: 14)
            }
        }
        .frame(width: 56, height: 48)
        .shadow(color: colors.last?.opacity(0.25) ?? .clear, radius: 4, y: 2)
        .accessibilityHidden(true)
    }
}
