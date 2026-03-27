import FluidAudio
import Foundation
import WhisperKit

enum BuiltInModelGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case parakeet
    case whisper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet:
            return "Parakeet"
        case .whisper:
            return "Whisper"
        }
    }
}

enum BuiltInModelID: String, CaseIterable, Codable, Identifiable, Sendable {
    case parakeetEnglishV2
    case whisperLargeV3Turbo

    var id: String { rawValue }

    var descriptor: BuiltInModelDescriptor {
        BuiltInModelCatalog.descriptor(for: self)
    }
}

struct BuiltInModelDescriptor: Identifiable, Equatable, Sendable {
    let id: BuiltInModelID
    let group: BuiltInModelGroup
    let title: String
    let detail: String
    let markdownLabel: String

    var installationPrompt: String {
        "\(title) is not installed. Open Settings > Model and install it."
    }
}

enum BuiltInModelCatalog {
    static let allModels: [BuiltInModelDescriptor] = [
        BuiltInModelDescriptor(
            id: .parakeetEnglishV2,
            group: .parakeet,
            title: "FluidAudio English",
            detail: "Parakeet TDT v2 • English only • Runs locally on-device",
            markdownLabel: "FluidAudio Parakeet v2"
        ),
        BuiltInModelDescriptor(
            id: .whisperLargeV3Turbo,
            group: .whisper,
            title: "Whisper Large V3 Turbo",
            detail: "WhisperKit • OpenAI Whisper large-v3-turbo • Runs locally on-device",
            markdownLabel: "Whisper Large V3 Turbo"
        ),
    ]

    static func descriptor(for id: BuiltInModelID) -> BuiltInModelDescriptor {
        guard let descriptor = allModels.first(where: { $0.id == id }) else {
            preconditionFailure("Unknown built-in model id: \(id.rawValue)")
        }
        return descriptor
    }

    static func models(in group: BuiltInModelGroup) -> [BuiltInModelDescriptor] {
        allModels.filter { $0.group == group }
    }
}

enum WhisperBuiltInConfiguration {
    static let modelRepo = "argmaxinc/whisperkit-coreml"
    static let modelVariant = "openai_whisper-large-v3_turbo"
    static let defaultLanguageCode = "en"

    static func decodingOptions() -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: defaultLanguageCode,
            temperature: 0.0,
            detectLanguage: false,
            withoutTimestamps: true,
            wordTimestamps: false
        )
    }
}

struct ModelInstallProgress: Sendable {
    let fractionCompleted: Double?
    let phase: String
}

typealias ModelInstallProgressHandler = @Sendable (ModelInstallProgress) -> Void

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

    @Published private(set) var installStates: [BuiltInModelID: NativeModelInstallState]

    private let service: LocalTranscriptionService
    private var installTasks: [BuiltInModelID: Task<Void, Never>] = [:]

    init(service: LocalTranscriptionService) {
        self.service = service
        self.installStates = Dictionary(
            uniqueKeysWithValues: BuiltInModelCatalog.allModels.map { ($0.id, .checking) }
        )
    }

    var selectedModelID: BuiltInModelID {
        SettingsStore.shared.selectedBuiltInModelID
    }

    var selectedModelDescriptor: BuiltInModelDescriptor {
        selectedModelID.descriptor
    }

    var isReady: Bool {
        isReady(for: selectedModelID)
    }

    func installState(for modelID: BuiltInModelID) -> NativeModelInstallState {
        installStates[modelID] ?? .checking
    }

    func isReady(for modelID: BuiltInModelID) -> Bool {
        if case .ready = installState(for: modelID) {
            return true
        }
        return false
    }

    func refresh() {
        guard installTasks.isEmpty else { return }
        Task { await refreshNow() }
    }

    func refreshNow() async {
        for model in BuiltInModelCatalog.allModels {
            await refresh(model.id)
        }
    }

    func refresh(_ modelID: BuiltInModelID) async {
        guard !isDownloading(modelID) else { return }

        setInstallState(.checking, for: modelID)

        do {
            let isInstalled = try await service.isModelInstalled(modelID)
            setInstallState(isInstalled ? .ready : .notInstalled, for: modelID)
        } catch {
            setInstallState(.failed(error.localizedDescription), for: modelID)
        }
    }

    func install(_ modelID: BuiltInModelID) {
        guard !isDownloading(modelID) else { return }

        installTasks[modelID]?.cancel()
        setInstallState(.downloading(progress: nil, phase: "Preparing model download…"), for: modelID)

        installTasks[modelID] = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor [weak self] in
                    self?.installTasks[modelID] = nil
                }
            }

            do {
                try await service.installModel(modelID) { progress in
                    Task { @MainActor [weak self] in
                        self?.setInstallState(
                            .downloading(
                                progress: progress.fractionCompleted,
                                phase: progress.phase
                            ),
                            for: modelID
                        )
                    }
                }

                if !Task.isCancelled {
                    await MainActor.run {
                        self.setInstallState(.ready, for: modelID)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.setInstallState(.failed(error.localizedDescription), for: modelID)
                    }
                }
            }
        }
    }

    private func isDownloading(_ modelID: BuiltInModelID) -> Bool {
        if case .downloading = installState(for: modelID) {
            return true
        }
        return false
    }

    private func setInstallState(_ state: NativeModelInstallState, for modelID: BuiltInModelID) {
        installStates[modelID] = state
    }
}

protocol BuiltInTranscriptionBackend: Sendable {
    func isInstalled(modelID: BuiltInModelID) async throws -> Bool
    func install(
        modelID: BuiltInModelID,
        progressHandler: ModelInstallProgressHandler?
    ) async throws
    func transcribe(
        modelID: BuiltInModelID,
        wavURL: URL,
        source: AudioSource
    ) async throws -> String
}

actor LocalTranscriptionService {
    static let shared = LocalTranscriptionService()

    private let backends: [BuiltInModelGroup: any BuiltInTranscriptionBackend]

    init(backends: [BuiltInModelGroup: any BuiltInTranscriptionBackend] = [
        .parakeet: ParakeetTranscriptionBackend(),
        .whisper: WhisperTranscriptionBackend(),
    ]) {
        self.backends = backends
    }

    func isModelInstalled(_ modelID: BuiltInModelID) async throws -> Bool {
        try await backend(for: modelID).isInstalled(modelID: modelID)
    }

    func installModel(
        _ modelID: BuiltInModelID,
        progressHandler: ModelInstallProgressHandler? = nil
    ) async throws {
        try await backend(for: modelID).install(modelID: modelID, progressHandler: progressHandler)
    }

    func transcribe(
        modelID: BuiltInModelID,
        wavURL: URL,
        source: AudioSource
    ) async throws -> String {
        try await backend(for: modelID).transcribe(modelID: modelID, wavURL: wavURL, source: source)
    }

    private func backend(for modelID: BuiltInModelID) -> any BuiltInTranscriptionBackend {
        let group = modelID.descriptor.group

        guard let backend = backends[group] else {
            fatalError("No transcription backend registered for \(group.rawValue)")
        }

        return backend
    }
}

actor ParakeetTranscriptionBackend: BuiltInTranscriptionBackend {
    private var manager: AsrManager?

    func isInstalled(modelID: BuiltInModelID) async throws -> Bool {
        guard case .parakeetEnglishV2 = modelID else {
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }
        return try await AsrModels.isModelValid(version: .v2)
    }

    func install(
        modelID: BuiltInModelID,
        progressHandler: ModelInstallProgressHandler?
    ) async throws {
        guard case .parakeetEnglishV2 = modelID else {
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }

        let models = try await AsrModels.downloadAndLoad(
            version: .v2,
            progressHandler: { progress in
                progressHandler?(
                    ModelInstallProgress(
                        fractionCompleted: progress.fractionCompleted,
                        phase: Self.phaseLabel(for: progress.phase)
                    )
                )
            }
        )

        try await prepareManager(with: models)
    }

    func transcribe(
        modelID: BuiltInModelID,
        wavURL: URL,
        source: AudioSource
    ) async throws -> String {
        try await ensureReady(modelID: modelID)

        guard let manager else {
            throw LocalTranscriptionError.notInitialized(modelID.descriptor)
        }

        let result = try await manager.transcribe(wavURL, source: source)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureReady(modelID: BuiltInModelID) async throws {
        if manager != nil {
            return
        }

        guard try await isInstalled(modelID: modelID) else {
            throw LocalTranscriptionError.modelNotInstalled(modelID.descriptor)
        }

        let models = try await AsrModels.loadFromCache(version: .v2)
        try await prepareManager(with: models)
    }

    private func prepareManager(with models: AsrModels) async throws {
        let manager = self.manager ?? AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.manager = manager
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

actor WhisperTranscriptionBackend: BuiltInTranscriptionBackend {
    private var whisperKit: WhisperKit?
    private var loadedModelPath: String?

    func isInstalled(modelID: BuiltInModelID) async throws -> Bool {
        guard case .whisperLargeV3Turbo = modelID else {
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }

        guard let modelPath = await persistedModelPath(for: modelID) else {
            return false
        }

        let isValid = Self.modelsExist(at: URL(fileURLWithPath: modelPath, isDirectory: true))
        if !isValid {
            await persistModelPath(nil, for: modelID)
        }
        return isValid
    }

    func install(
        modelID: BuiltInModelID,
        progressHandler: ModelInstallProgressHandler?
    ) async throws {
        guard case .whisperLargeV3Turbo = modelID else {
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }

        let modelFolder = try await WhisperKit.download(
            variant: WhisperBuiltInConfiguration.modelVariant,
            from: WhisperBuiltInConfiguration.modelRepo,
            progressCallback: { progress in
                progressHandler?(
                    ModelInstallProgress(
                        fractionCompleted: progress.fractionCompleted,
                        phase: Self.phaseLabel(for: progress)
                    )
                )
            }
        )

        await persistModelPath(modelFolder.path, for: modelID)
        progressHandler?(ModelInstallProgress(fractionCompleted: 1.0, phase: "Loading model…"))
        _ = try await prepareWhisperKit(modelID: modelID, modelPath: modelFolder.path, forceReload: true)
    }

    func transcribe(
        modelID: BuiltInModelID,
        wavURL: URL,
        source _: AudioSource
    ) async throws -> String {
        let whisperKit = try await ensureReady(modelID: modelID)
        let results = try await whisperKit.transcribe(
            audioPath: wavURL.path,
            decodeOptions: WhisperBuiltInConfiguration.decodingOptions()
        )

        return results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureReady(modelID: BuiltInModelID) async throws -> WhisperKit {
        guard let modelPath = await persistedModelPath(for: modelID) else {
            throw LocalTranscriptionError.modelNotInstalled(modelID.descriptor)
        }

        guard Self.modelsExist(at: URL(fileURLWithPath: modelPath, isDirectory: true)) else {
            await persistModelPath(nil, for: modelID)
            throw LocalTranscriptionError.modelNotInstalled(modelID.descriptor)
        }

        return try await prepareWhisperKit(modelID: modelID, modelPath: modelPath)
    }

    private func prepareWhisperKit(
        modelID _: BuiltInModelID,
        modelPath: String,
        forceReload: Bool = false
    ) async throws -> WhisperKit {
        if !forceReload, let whisperKit, loadedModelPath == modelPath {
            return whisperKit
        }

        let whisperKit = try await WhisperKit(
            WhisperKitConfig(
                model: WhisperBuiltInConfiguration.modelVariant,
                modelRepo: WhisperBuiltInConfiguration.modelRepo,
                modelFolder: modelPath,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )
        )

        self.whisperKit = whisperKit
        self.loadedModelPath = modelPath
        return whisperKit
    }

    private func persistedModelPath(for modelID: BuiltInModelID) async -> String? {
        await MainActor.run {
            SettingsStore.shared.localModelPath(for: modelID)
        }
    }

    private func persistModelPath(_ path: String?, for modelID: BuiltInModelID) async {
        await MainActor.run {
            SettingsStore.shared.setLocalModelPath(path, for: modelID)
        }
    }

    private static func modelsExist(at folder: URL) -> Bool {
        let requiredModelNames = [
            "MelSpectrogram",
            "AudioEncoder",
            "TextDecoder",
        ]

        return requiredModelNames.allSatisfy { name in
            let compiled = folder.appendingPathComponent("\(name).mlmodelc")
            let package = folder.appendingPathComponent("\(name).mlpackage")
            return FileManager.default.fileExists(atPath: compiled.path)
                || FileManager.default.fileExists(atPath: package.path)
        }
    }

    private static func phaseLabel(for progress: Progress) -> String {
        if let additionalDescription = progress.localizedAdditionalDescription,
           !additionalDescription.isEmpty {
            return additionalDescription
        }
        return "Downloading model files…"
    }
}

enum LocalTranscriptionError: LocalizedError {
    case modelNotInstalled(BuiltInModelDescriptor)
    case notInitialized(BuiltInModelDescriptor)
    case unsupportedModel(BuiltInModelID)

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let descriptor):
            return descriptor.installationPrompt
        case .notInitialized(let descriptor):
            return "\(descriptor.title) is not ready yet."
        case .unsupportedModel(let modelID):
            return "Unsupported transcription model: \(modelID.rawValue)"
        }
    }
}
