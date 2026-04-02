import SwiftUI

struct PostProcessingSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var modelStore = LocalLLMModelStore.shared

    private var editablePromptBinding: Binding<String> {
        Binding(
            get: {
                let override = store.cleanupPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines)
                if override.isEmpty {
                    return PromptBuilder.defaultCleanupInstructions(cleanupLevel: .medium)
                }
                return store.cleanupPromptOverride
            },
            set: { newValue in
                store.cleanupPromptOverride = newValue
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Post-processing")
                        .font(.title3.bold())
                    Text("Clean up transcriptions before Whale inserts or saves them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                settingsSection

                if LocalLLMService.isSupported {
                    localModelSection
                } else {
                    unsupportedSection
                }

                previewSection
            }
            .padding(18)
        }
        .onAppear {
            modelStore.refresh()
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Clean up transcriptions", isOn: $store.postProcessingEnabled)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cleanup prompt")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Reset") {
                        store.cleanupPromptOverride = ""
                    }
                    .disabled(store.cleanupPromptOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("This edits the instruction prompt sent to the local LLM. The transcript text is appended automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: editablePromptBinding)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150, maxHeight: 220)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!store.postProcessingEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var localModelSection: some View {
        if store.postProcessingEnabled {
            VStack(alignment: .leading, spacing: 12) {
                Text("Local AI Model")
                    .font(.headline)

                ForEach(LocalLLMModelCatalog.allModels) { model in
                    LocalLLMModelCard(model: model)
                }
            }
        }
    }

    private var unsupportedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local AI cleanup requires Apple Silicon.")
                .font(.callout.weight(.medium))
            Text("On Intel Macs, Whale will skip post-processing and keep the raw transcript.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent transcription previews")
                .font(.headline)

            if appState.recentTranscriptionPreviews.isEmpty {
                Text("No transcriptions yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(appState.recentTranscriptionPreviews.enumerated()), id: \.element.id) { index, entry in
                        previewEntry(entry, index: index)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func previewEntry(_ entry: TranscriptionPreviewEntry, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(index == 0 ? "Latest" : "Recent #\(index + 1)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                previewColumn(title: "Raw", text: entry.rawTranscript)
                previewColumn(title: "Cleaned", text: entry.cleanedTranscript)
            }

            if !entry.warnings.isEmpty {
                Text(entry.warnings.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func previewColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ScrollView {
                Text(text.isEmpty ? "No transcription yet." : text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 90, maxHeight: 140)
            .padding(10)
            .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LocalLLMModelCard: View {
    @ObservedObject private var modelStore = LocalLLMModelStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    let model: LocalLLMModelDescriptor

    private var isSelected: Bool {
        settings.selectedLocalLLMModelID == model.id
    }

    private var installState: NativeModelInstallState {
        modelStore.installState(for: model.id)
    }

    private var canSelect: Bool {
        modelStore.isReady(for: model.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    guard canSelect else { return }
                    settings.selectedLocalLLMModelID = model.id
                } label: {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSelect)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.title)
                            .font(.headline)
                        if model.recommended {
                            Text("Recommended")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }

                    Text("\(model.detail) • \(model.sizeLabel)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                actionView
            }

            statusView
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var actionView: some View {
        switch installState {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .notInstalled:
            Button("Install") {
                modelStore.install(model.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .downloading(let progress, _):
            Text(progress.map { "\(Int($0 * 100))%" } ?? "Working…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .ready:
            Label(isSelected ? "Selected" : "Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))
        case .failed:
            Button("Retry") {
                modelStore.install(model.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch installState {
        case .checking:
            Text("Checking the local model cache…")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .notInstalled:
            Text("Install this model to enable AI cleanup.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .downloading(_, let phase):
            Text(phase)
                .font(.callout)
                .foregroundStyle(.secondary)
        case .ready:
            Text(isSelected ? "Selected for AI cleanup." : "Installed and ready.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
