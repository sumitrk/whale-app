import FluidAudio
import Foundation

enum NativeModelInstallState: Equatable {
    case checking
    case notInstalled
    case downloading(progress: Double?, phase: String)
    case ready
    case failed(String)
}

@MainActor
final class TranscriptionModelStore: ObservableObject {
    static let shared = TranscriptionModelStore(service: .shared)

    @Published private(set) var installState: NativeModelInstallState = .checking

    private let service: LocalTranscriptionService
    private var installTask: Task<Void, Never>?

    private init(service: LocalTranscriptionService) {
        self.service = service
    }

    var isReady: Bool {
        if case .ready = installState {
            return true
        }
        return false
    }

    func refresh() {
        guard !isDownloading else { return }
        Task { await refreshNow() }
    }

    func refreshNow() async {
        do {
            let isInstalled = try await service.isModelInstalled()
            installState = isInstalled ? .ready : .notInstalled
        } catch {
            installState = .failed(error.localizedDescription)
        }
    }

    func install() {
        guard !isDownloading else { return }

        installTask?.cancel()
        installState = .downloading(progress: nil, phase: "Preparing model download…")

        installTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await service.installModel { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.installState = .downloading(
                            progress: progress.fractionCompleted,
                            phase: Self.phaseLabel(for: progress.phase)
                        )
                    }
                }

                if !Task.isCancelled {
                    installState = .ready
                }
            } catch {
                if !Task.isCancelled {
                    installState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private var isDownloading: Bool {
        if case .downloading = installState {
            return true
        }
        return false
    }

    private static func phaseLabel(for phase: DownloadUtils.DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Looking up model files…"
        case .downloading(let completedFiles, let totalFiles):
            return "Downloading model files \(completedFiles)/\(totalFiles)…"
        case .compiling(let modelName):
            return "Compiling \(modelName)…"
        }
    }
}

actor LocalTranscriptionService {
    static let shared = LocalTranscriptionService()

    static let modelVersion: AsrModelVersion = .v2
    static let modelDisplayName = "FluidAudio English"
    static let modelDetail = "Parakeet TDT v2 • English only • Runs locally on-device"
    static let markdownModelName = "FluidAudio Parakeet v2"

    private var manager: AsrManager?

    func isModelInstalled() async throws -> Bool {
        try await AsrModels.isModelValid(version: Self.modelVersion)
    }

    func installModel(progressHandler: DownloadUtils.ProgressHandler? = nil) async throws {
        let models = try await AsrModels.downloadAndLoad(
            version: Self.modelVersion,
            progressHandler: progressHandler
        )
        try await prepareManager(with: models)
    }

    func transcribe(wavURL: URL, source: AudioSource) async throws -> String {
        try await ensureReady()

        guard let manager else {
            throw LocalTranscriptionError.notInitialized
        }

        let result = try await manager.transcribe(wavURL, source: source)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureReady() async throws {
        if manager != nil {
            return
        }

        guard try await isModelInstalled() else {
            throw LocalTranscriptionError.modelNotInstalled
        }

        let models = try await AsrModels.loadFromCache(version: Self.modelVersion)
        try await prepareManager(with: models)
    }

    private func prepareManager(with models: AsrModels) async throws {
        let manager = self.manager ?? AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.manager = manager
    }
}

enum LocalTranscriptionError: LocalizedError {
    case modelNotInstalled
    case notInitialized

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled:
            return "No transcription model is installed. Open Settings > Model and download the English model."
        case .notInitialized:
            return "The local transcription engine is not ready yet."
        }
    }
}
