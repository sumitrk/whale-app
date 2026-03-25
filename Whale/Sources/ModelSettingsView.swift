import SwiftUI

struct ModelSettingsView: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription model")
                    .font(.title3.bold())
                Text("FluidAudio runs locally on this Mac. Download once, then transcription works offline.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(.horizontal, 18)

            NativeModelInstallCard(contentPadding: 18)
                .padding(.horizontal, 18)

            if case .ready = modelStore.installState {
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

struct NativeModelInstallCard: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared
    var contentPadding: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalTranscriptionService.modelDisplayName)
                        .font(.headline)
                    Text(LocalTranscriptionService.modelDetail)
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
        switch modelStore.installState {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .notInstalled:
            Button("Download", action: modelStore.install)
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
            Button("Retry", action: modelStore.install)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch modelStore.installState {
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking the local FluidAudio model cache…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .notInstalled:
            Text("Download the English model to enable dictation and meeting transcription.")
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
            Text("Installed and ready. After this one-time download, transcription continues working without a network connection.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var progressLabel: String {
        if case .downloading(let progress, _) = modelStore.installState,
           let progress {
            return "\(Int(progress * 100))%"
        }
        return "Working…"
    }
}
