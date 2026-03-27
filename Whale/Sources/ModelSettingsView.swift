import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared

    var body: some View {
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

            Spacer()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    settings.selectedBuiltInModelID = model.id
                } label: {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

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
            Button("Install") {
                modelStore.install(model.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        case .downloading:
            Text(progressLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .ready:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .fontWeight(.medium)
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
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking the local model cache…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .notInstalled:
            Text(
                isSelected
                    ? "\(model.title) is selected, but not installed yet. Install it to use dictation and meeting transcription."
                    : "Install this model to make it available for dictation and meeting transcription."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .downloading(let progress, let phase):
            VStack(alignment: .leading, spacing: 8) {
                Text(phase)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress)
                        .tint(.blue)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        case .ready:
            Text(
                isSelected
                    ? "Selected and ready. New recordings will use this model."
                    : "Installed and ready. Select this model whenever you want to switch."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var progressLabel: String {
        if case .downloading(let progress, _) = installState,
           let progress {
            return "\(Int(progress * 100))%"
        }
        return "Working…"
    }
}
