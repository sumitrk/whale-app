import CoreML
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

enum BuiltInModelProvisioning: String, Codable, Sendable {
    case download
    case localFolder
}

enum BuiltInModelID: String, CaseIterable, Codable, Identifiable, Sendable {
    case parakeetEnglishV2
    case whisperLargeV3Turbo
    case whisperLocalFolder

    var id: String { rawValue }

    var descriptor: BuiltInModelDescriptor {
        BuiltInModelCatalog.descriptor(for: self)
    }
}

struct BuiltInModelDescriptor: Identifiable, Equatable, Sendable {
    let id: BuiltInModelID
    let group: BuiltInModelGroup
    let provisioning: BuiltInModelProvisioning
    let title: String
    let detail: String
    let markdownLabel: String

    var installationPrompt: String {
        switch provisioning {
        case .download:
            return "\(title) is not installed. Open Settings > Model and install it."
        case .localFolder:
            return "\(title) is not configured yet. Open Settings > Model, choose a WhisperKit/Core ML folder, and try again."
        }
    }

    var actionTitle: String {
        switch provisioning {
        case .download:
            return "Install"
        case .localFolder:
            return "Choose Folder"
        }
    }

    var retryActionTitle: String {
        switch provisioning {
        case .download:
            return "Retry"
        case .localFolder:
            return "Choose Another Folder"
        }
    }

    var changeActionTitle: String? {
        switch provisioning {
        case .download:
            return nil
        case .localFolder:
            return "Change Folder"
        }
    }

    var resetActionTitle: String? {
        switch id {
        case .parakeetEnglishV2:
            return "Reset Cache"
        case .whisperLargeV3Turbo, .whisperLocalFolder:
            return nil
        }
    }
}

enum BuiltInModelCatalog {
    static let allModels: [BuiltInModelDescriptor] = [
        BuiltInModelDescriptor(
            id: .parakeetEnglishV2,
            group: .parakeet,
            provisioning: .download,
            title: "FluidAudio English",
            detail: "Parakeet TDT v2 • English only • Runs locally on-device",
            markdownLabel: "FluidAudio Parakeet v2"
        ),
        BuiltInModelDescriptor(
            id: .whisperLargeV3Turbo,
            group: .whisper,
            provisioning: .download,
            title: "Whisper Large V3 Turbo",
            detail: "WhisperKit • OpenAI Whisper large-v3-turbo • Runs locally on-device",
            markdownLabel: "Whisper Large V3 Turbo"
        ),
        BuiltInModelDescriptor(
            id: .whisperLocalFolder,
            group: .whisper,
            provisioning: .localFolder,
            title: "Local Whisper Folder",
            detail: "WhisperKit/Core ML • Choose a converted local model folder from your Mac",
            markdownLabel: "Local Whisper Model"
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

struct WhisperModelValidationResult: Sendable {
    let modelFolder: URL
    let tokenizerFolder: URL?
    let inferredModelName: String?
}

enum ParakeetInstallStep: String, Sendable {
    case resolvingStorage
    case downloading
    case validatingFiles
    case loadingModels
    case preparingRuntime
    case firstUse
    case resettingCache

    var title: String {
        switch self {
        case .resolvingStorage:
            return "Resolving model storage"
        case .downloading:
            return "Downloading model files"
        case .validatingFiles:
            return "Validating model files"
        case .loadingModels:
            return "Loading model files"
        case .preparingRuntime:
            return "Preparing model runtime"
        case .firstUse:
            return "Running Parakeet"
        case .resettingCache:
            return "Resetting model cache"
        }
    }
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

    func reset(_ modelID: BuiltInModelID) {
        guard !isDownloading(modelID) else { return }

        installTasks[modelID]?.cancel()
        setInstallState(.checking, for: modelID)

        installTasks[modelID] = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor [weak self] in
                    self?.installTasks[modelID] = nil
                }
            }

            do {
                try await service.resetModel(modelID)

                if !Task.isCancelled {
                    await MainActor.run {
                        self.setInstallState(.notInstalled, for: modelID)
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

    func connectLocalModel(_ modelID: BuiltInModelID, folderURL: URL) {
        guard !isDownloading(modelID) else { return }

        installTasks[modelID]?.cancel()
        setInstallState(.downloading(progress: nil, phase: "Validating local model folder…"), for: modelID)

        installTasks[modelID] = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor [weak self] in
                    self?.installTasks[modelID] = nil
                }
            }

            do {
                try await service.connectLocalModel(modelID, folderURL: folderURL) { progress in
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
        reconcileSelection()
    }

    private func reconcileSelection() {
        let selectedModelID = SettingsStore.shared.selectedBuiltInModelID
        switch installState(for: selectedModelID) {
        case .ready, .checking, .downloading:
            return
        case .notInstalled, .failed:
            break
        }

        let fallback = preferredReadyModelID()
        guard let fallback, fallback != selectedModelID else { return }

        SettingsStore.shared.selectedBuiltInModelID = fallback
    }

    private func preferredReadyModelID() -> BuiltInModelID? {
        if isReady(for: .parakeetEnglishV2) {
            return .parakeetEnglishV2
        }

        return BuiltInModelCatalog.allModels
            .map(\.id)
            .first(where: { isReady(for: $0) })
    }
}

protocol BuiltInTranscriptionBackend: Sendable {
    func isInstalled(modelID: BuiltInModelID) async throws -> Bool
    func install(
        modelID: BuiltInModelID,
        progressHandler: ModelInstallProgressHandler?
    ) async throws
    func connectLocalModel(
        modelID: BuiltInModelID,
        folderURL: URL,
        progressHandler: ModelInstallProgressHandler?
    ) async throws
    func transcribe(
        modelID: BuiltInModelID,
        wavURL: URL,
        source: AudioSource
    ) async throws -> String
    func resetModel(modelID: BuiltInModelID) async throws
}

extension BuiltInTranscriptionBackend {
    func connectLocalModel(
        modelID: BuiltInModelID,
        folderURL _: URL,
        progressHandler _: ModelInstallProgressHandler?
    ) async throws {
        throw LocalTranscriptionError.unsupportedModel(modelID)
    }

    func resetModel(modelID: BuiltInModelID) async throws {
        throw LocalTranscriptionError.unsupportedModel(modelID)
    }
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

    func connectLocalModel(
        _ modelID: BuiltInModelID,
        folderURL: URL,
        progressHandler: ModelInstallProgressHandler? = nil
    ) async throws {
        try await backend(for: modelID).connectLocalModel(
            modelID: modelID,
            folderURL: folderURL,
            progressHandler: progressHandler
        )
    }

    func transcribe(
        modelID: BuiltInModelID,
        wavURL: URL,
        source: AudioSource
    ) async throws -> String {
        try await backend(for: modelID).transcribe(modelID: modelID, wavURL: wavURL, source: source)
    }

    func resetModel(_ modelID: BuiltInModelID) async throws {
        try await backend(for: modelID).resetModel(modelID: modelID)
    }

    private func backend(for modelID: BuiltInModelID) -> any BuiltInTranscriptionBackend {
        let group = modelID.descriptor.group

        guard let backend = backends[group] else {
            fatalError("No transcription backend registered for \(group.rawValue)")
        }

        return backend
    }
}

protocol ParakeetManaging: Sendable {
    func transcribe(_ wavURL: URL, source: AudioSource) async throws -> String
    func transcribeStreaming(_ wavURL: URL, source: AudioSource) async throws -> String
}

protocol ParakeetModelRuntime: Sendable {
    func modelsExist(at modelDirectory: URL) async -> Bool
    func downloadModels(
        to modelDirectory: URL,
        progressHandler: DownloadUtils.ProgressHandler?
    ) async throws
    func validateModels(at modelDirectory: URL) async throws
    func prepareManager(at modelDirectory: URL) async throws -> any ParakeetManaging
}

struct FluidAudioParakeetRuntime: ParakeetModelRuntime {
    func modelsExist(at modelDirectory: URL) async -> Bool {
        AsrModels.modelsExist(at: modelDirectory, version: .v2)
    }

    func downloadModels(
        to modelDirectory: URL,
        progressHandler: DownloadUtils.ProgressHandler?
    ) async throws {
        _ = try await AsrModels.download(
            to: modelDirectory,
            version: .v2,
            progressHandler: progressHandler
        )
    }

    func validateModels(at modelDirectory: URL) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        _ = try await AsrModels.load(
            from: modelDirectory,
            configuration: configuration,
            version: .v2
        )
    }

    func prepareManager(at modelDirectory: URL) async throws -> any ParakeetManaging {
        let models: AsrModels

        do {
            models = try await AsrModels.load(from: modelDirectory, version: .v2)
        } catch {
            throw LocalTranscriptionError.parakeetSetupFailed(
                step: .loadingModels,
                modelDirectory: modelDirectory.path,
                reason: error.localizedDescription
            )
        }

        let manager = AsrManager(config: .default)

        do {
            try await manager.initialize(models: models)
        } catch {
            throw LocalTranscriptionError.parakeetSetupFailed(
                step: .preparingRuntime,
                modelDirectory: modelDirectory.path,
                reason: error.localizedDescription
            )
        }

        return FluidAudioParakeetManager(manager: manager)
    }
}

private final class FluidAudioParakeetManager: @unchecked Sendable, ParakeetManaging {
    private let manager: AsrManager

    init(manager: AsrManager) {
        self.manager = manager
    }

    func transcribe(_ wavURL: URL, source: AudioSource) async throws -> String {
        let result = try await manager.transcribe(wavURL, source: source)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribeStreaming(_ wavURL: URL, source: AudioSource) async throws -> String {
        let result = try await manager.transcribeStreaming(wavURL, source: source)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

actor ParakeetTranscriptionBackend: BuiltInTranscriptionBackend {
    private let runtime: any ParakeetModelRuntime
    private let runtimeInfoProvider: @Sendable () -> AppRuntimeInfo
    private var manager: (any ParakeetManaging)?
    private var loadedModelDirectory: URL?

    init(
        runtime: any ParakeetModelRuntime = FluidAudioParakeetRuntime(),
        runtimeInfoProvider: @escaping @Sendable () -> AppRuntimeInfo = { AppRuntimeInfo.current }
    ) {
        self.runtime = runtime
        self.runtimeInfoProvider = runtimeInfoProvider
    }

    func isInstalled(modelID: BuiltInModelID) async throws -> Bool {
        let context = try modelContext(for: modelID)
        Self.log("Checking install state at \(context.modelDirectory.path) (\(context.runtimeInfo.storageDescription))")

        guard await runtime.modelsExist(at: context.modelDirectory) else {
            Self.log("Model files missing at \(context.modelDirectory.path)")
            return false
        }

        do {
            try await runtime.validateModels(at: context.modelDirectory)
            Self.log("Validated model files at \(context.modelDirectory.path)")
            return true
        } catch {
            Self.log("Validation failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .validatingFiles,
                modelDirectory: context.modelDirectory.path
            )
        }
    }

    func install(
        modelID: BuiltInModelID,
        progressHandler: ModelInstallProgressHandler?
    ) async throws {
        let context = try modelContext(for: modelID)
        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: "Resolving model storage…"))
        Self.log("Installing model at \(context.modelDirectory.path) (\(context.runtimeInfo.storageDescription))")

        do {
            try prepareStorageDirectories(for: context.runtimeInfo)
        } catch {
            Self.log("Storage resolution failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .resolvingStorage,
                modelDirectory: context.modelDirectory.path
            )
        }

        do {
            try await runtime.downloadModels(
                to: context.modelDirectory,
                progressHandler: { progress in
                    progressHandler?(
                        ModelInstallProgress(
                            fractionCompleted: progress.fractionCompleted,
                            phase: Self.phaseLabel(for: progress.phase)
                        )
                    )
                }
            )
        } catch {
            Self.log("Download failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .downloading,
                modelDirectory: context.modelDirectory.path
            )
        }

        progressHandler?(ModelInstallProgress(fractionCompleted: 1.0, phase: "Validating model files…"))

        guard await runtime.modelsExist(at: context.modelDirectory) else {
            let reason = "Expected Parakeet model files were not found after download."
            Self.log("Validation failed at \(context.modelDirectory.path): \(reason)")
            throw LocalTranscriptionError.parakeetSetupFailed(
                step: .validatingFiles,
                modelDirectory: context.modelDirectory.path,
                reason: reason
            )
        }

        do {
            try await runtime.validateModels(at: context.modelDirectory)
        } catch {
            Self.log("Validation failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .validatingFiles,
                modelDirectory: context.modelDirectory.path
            )
        }

        progressHandler?(ModelInstallProgress(fractionCompleted: 1.0, phase: "Preparing model for first use…"))

        do {
            manager = try await runtime.prepareManager(at: context.modelDirectory)
            loadedModelDirectory = context.modelDirectory
            Self.log("Model runtime prepared at \(context.modelDirectory.path)")
        } catch {
            Self.log("Runtime preparation failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .preparingRuntime,
                modelDirectory: context.modelDirectory.path
            )
        }
    }

    func transcribe(
        modelID: BuiltInModelID,
        wavURL: URL,
        source: AudioSource
    ) async throws -> String {
        let context = try modelContext(for: modelID)
        Self.log("Transcribing with model at \(context.modelDirectory.path)")
        try await ensureReady(modelID: modelID)

        guard let manager else {
            throw LocalTranscriptionError.notInitialized(modelID.descriptor)
        }

        do {
            let result = try await manager.transcribe(wavURL, source: source)
            if !result.isEmpty {
                return result
            }

            Self.log("Standard transcription returned empty text at \(context.modelDirectory.path); retrying in streaming mode")
        } catch {
            Self.log("Standard transcription failed at \(context.modelDirectory.path): \(error.localizedDescription)")
        }

        do {
            return try await manager.transcribeStreaming(wavURL, source: source)
        } catch {
            Self.log("Streaming transcription failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .firstUse,
                modelDirectory: context.modelDirectory.path
            )
        }
    }

    func resetModel(modelID: BuiltInModelID) async throws {
        let context = try modelContext(for: modelID)
        Self.log("Resetting model cache at \(context.modelDirectory.path)")
        manager = nil
        loadedModelDirectory = nil

        do {
            if FileManager.default.fileExists(atPath: context.modelDirectory.path) {
                try FileManager.default.removeItem(at: context.modelDirectory)
            }
        } catch {
            Self.log("Reset failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .resettingCache,
                modelDirectory: context.modelDirectory.path
            )
        }
    }

    private func ensureReady(modelID: BuiltInModelID) async throws {
        let context = try modelContext(for: modelID)

        if manager != nil, loadedModelDirectory == context.modelDirectory {
            return
        }

        Self.log("Ensuring model runtime is ready at \(context.modelDirectory.path)")

        guard await runtime.modelsExist(at: context.modelDirectory) else {
            throw LocalTranscriptionError.modelNotInstalled(modelID.descriptor)
        }

        do {
            try await runtime.validateModels(at: context.modelDirectory)
        } catch {
            Self.log("Validation failed while preparing runtime at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .validatingFiles,
                modelDirectory: context.modelDirectory.path
            )
        }

        do {
            manager = try await runtime.prepareManager(at: context.modelDirectory)
            loadedModelDirectory = context.modelDirectory
        } catch {
            Self.log("Runtime preparation failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .preparingRuntime,
                modelDirectory: context.modelDirectory.path
            )
        }
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

    private func modelContext(for modelID: BuiltInModelID) throws -> (runtimeInfo: AppRuntimeInfo, modelDirectory: URL) {
        guard case .parakeetEnglishV2 = modelID else {
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }

        let runtimeInfo = runtimeInfoProvider()
        return (
            runtimeInfo: runtimeInfo,
            modelDirectory: runtimeInfo.parakeetEnglishV2DirectoryURL
        )
    }

    private func prepareStorageDirectories(for runtimeInfo: AppRuntimeInfo) throws {
        try FileManager.default.createDirectory(
            at: runtimeInfo.modelsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private static func wrapError(
        _ error: Error,
        step: ParakeetInstallStep,
        modelDirectory: String
    ) -> Error {
        if let localError = error as? LocalTranscriptionError {
            return localError
        }

        return LocalTranscriptionError.parakeetSetupFailed(
            step: step,
            modelDirectory: modelDirectory,
            reason: error.localizedDescription
        )
    }

    private static func log(_ message: String) {
        let line = "[Parakeet] \(message)"
        print(line)
        DiagnosticLog.log(line)
    }
}

actor WhisperTranscriptionBackend: BuiltInTranscriptionBackend {
    private var whisperKit: WhisperKit?
    private var loadedModelPath: String?

    func isInstalled(modelID: BuiltInModelID) async throws -> Bool {
        guard modelID.descriptor.group == .whisper else {
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }

        guard let modelURL = await persistedModelURL(for: modelID) else {
            return false
        }

        _ = try Self.validateStoredModelFolder(
            for: modelID,
            modelURL: modelURL
        )
        return true
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
        let validation = try Self.validateStoredModelFolder(for: modelID, modelURL: modelFolder)
        _ = try await prepareWhisperKit(
            runtime: Self.runtimeConfiguration(for: modelID, validation: validation),
            forceReload: true
        )
    }

    func connectLocalModel(
        modelID: BuiltInModelID,
        folderURL: URL,
        progressHandler: ModelInstallProgressHandler?
    ) async throws {
        guard case .whisperLocalFolder = modelID else {
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }

        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: "Inspecting WhisperKit artifacts…"))
        let validation = try Self.validateSelectedLocalModelFolder(
            folderURL,
            descriptor: modelID.descriptor
        )
        await persistLocalModelURL(validation.modelFolder, for: modelID)
        progressHandler?(ModelInstallProgress(fractionCompleted: 1.0, phase: "Loading model…"))
        _ = try await prepareWhisperKit(
            runtime: Self.runtimeConfiguration(for: modelID, validation: validation),
            forceReload: true
        )
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
        guard let modelURL = await persistedModelURL(for: modelID) else {
            throw LocalTranscriptionError.modelNotInstalled(modelID.descriptor)
        }

        let validation = try Self.validateStoredModelFolder(for: modelID, modelURL: modelURL)
        return try await prepareWhisperKit(
            runtime: Self.runtimeConfiguration(for: modelID, validation: validation)
        )
    }

    private func prepareWhisperKit(
        runtime: WhisperRuntimeConfiguration,
        forceReload: Bool = false
    ) async throws -> WhisperKit {
        if !forceReload, let whisperKit, loadedModelPath == runtime.modelFolderPath {
            return whisperKit
        }

        let whisperKit = try await WhisperKit(
            WhisperKitConfig(
                model: runtime.modelName,
                modelRepo: runtime.modelRepo,
                modelFolder: runtime.modelFolderPath,
                tokenizerFolder: runtime.tokenizerFolder,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )
        )

        self.whisperKit = whisperKit
        self.loadedModelPath = runtime.modelFolderPath
        return whisperKit
    }

    private func persistedModelURL(for modelID: BuiltInModelID) async -> URL? {
        await MainActor.run {
            switch modelID {
            case .whisperLocalFolder:
                return SettingsStore.shared.localModelURL(for: modelID)
            default:
                guard let path = SettingsStore.shared.localModelPath(for: modelID) else {
                    return nil
                }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
    }

    private func persistModelPath(_ path: String?, for modelID: BuiltInModelID) async {
        await MainActor.run {
            SettingsStore.shared.setLocalModelPath(path, for: modelID)
        }
    }

    private func persistLocalModelURL(_ url: URL?, for modelID: BuiltInModelID) async {
        await MainActor.run {
            SettingsStore.shared.setLocalModelURL(url, for: modelID)
        }
    }

    private static func validateStoredModelFolder(
        for modelID: BuiltInModelID,
        modelURL: URL
    ) throws -> WhisperModelValidationResult {
        switch modelID {
        case .whisperLargeV3Turbo:
            return try validateModelFolder(at: modelURL, descriptor: modelID.descriptor)
        case .whisperLocalFolder:
            return try validateModelFolder(at: modelURL, descriptor: modelID.descriptor)
        default:
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }
    }

    private static func validateSelectedLocalModelFolder(
        _ folder: URL,
        descriptor: BuiltInModelDescriptor
    ) throws -> WhisperModelValidationResult {
        try validateModelFolder(at: folder, descriptor: descriptor)
    }

    static func validateModelFolder(
        at folder: URL,
        descriptor: BuiltInModelDescriptor
    ) throws -> WhisperModelValidationResult {
        let fileManager = FileManager.default

        var issues: [String] = []

        if !fileManager.fileExists(atPath: folder.path) {
            issues.append("The selected folder no longer exists at \(folder.path).")
        }

        let requiredModelNames = [
            "MelSpectrogram",
            "AudioEncoder",
            "TextDecoder",
        ]

        for name in requiredModelNames {
            let compiled = folder.appendingPathComponent("\(name).mlmodelc")
            let package = folder.appendingPathComponent("\(name).mlpackage")

            if !fileManager.fileExists(atPath: compiled.path)
                && !fileManager.fileExists(atPath: package.path) {
                issues.append("Missing \(name).mlmodelc or \(name).mlpackage.")
            }
        }

        let tokenizerURL = folder.appendingPathComponent("tokenizer.json")
        if !issues.isEmpty {
            throw LocalTranscriptionError.invalidWhisperModelFolder(
                descriptor: descriptor,
                folderPath: folder.path,
                issues: issues
            )
        }

        return WhisperModelValidationResult(
            modelFolder: folder,
            tokenizerFolder: fileManager.fileExists(atPath: tokenizerURL.path)
                ? tokenizerURL.deletingLastPathComponent()
                : nil,
            inferredModelName: inferModelName(from: folder)
        )
    }

    private static func runtimeConfiguration(
        for modelID: BuiltInModelID,
        validation: WhisperModelValidationResult
    ) -> WhisperRuntimeConfiguration {
        switch modelID {
        case .whisperLargeV3Turbo:
            return WhisperRuntimeConfiguration(
                modelName: WhisperBuiltInConfiguration.modelVariant,
                modelRepo: WhisperBuiltInConfiguration.modelRepo,
                modelFolderPath: validation.modelFolder.path,
                tokenizerFolder: validation.tokenizerFolder
            )
        case .whisperLocalFolder:
            return WhisperRuntimeConfiguration(
                modelName: validation.inferredModelName,
                modelRepo: nil,
                modelFolderPath: validation.modelFolder.path,
                tokenizerFolder: validation.tokenizerFolder
            )
        default:
            return WhisperRuntimeConfiguration(
                modelName: WhisperBuiltInConfiguration.modelVariant,
                modelRepo: WhisperBuiltInConfiguration.modelRepo,
                modelFolderPath: validation.modelFolder.path,
                tokenizerFolder: nil
            )
        }
    }

    private static func phaseLabel(for progress: Progress) -> String {
        if let additionalDescription = progress.localizedAdditionalDescription,
           !additionalDescription.isEmpty {
            return additionalDescription
        }
        return "Downloading model files…"
    }

    private static func inferModelName(from folder: URL) -> String? {
        let folderName = folder.lastPathComponent
        return folderName.isEmpty ? nil : folderName
    }
}

enum LocalTranscriptionError: LocalizedError {
    case modelNotInstalled(BuiltInModelDescriptor)
    case notInitialized(BuiltInModelDescriptor)
    case unsupportedModel(BuiltInModelID)
    case parakeetSetupFailed(
        step: ParakeetInstallStep,
        modelDirectory: String,
        reason: String
    )
    case invalidWhisperModelFolder(
        descriptor: BuiltInModelDescriptor,
        folderPath: String,
        issues: [String]
    )

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let descriptor):
            return descriptor.installationPrompt
        case .notInitialized(let descriptor):
            return "\(descriptor.title) is not ready yet."
        case .unsupportedModel(let modelID):
            return "Unsupported transcription model: \(modelID.rawValue)"
        case .parakeetSetupFailed(let step, let modelDirectory, let reason):
            return """
            FluidAudio English could not be prepared.

            Step:
            \(step.title)

            Storage:
            \(modelDirectory)

            Reason:
            \(reason)

            Use Reset Cache in Settings > Model, then install Parakeet again.
            """
        case .invalidWhisperModelFolder(let descriptor, let folderPath, let issues):
            let bulletList = issues.map { "• \($0)" }.joined(separator: "\n")

            return """
            \(descriptor.title) could not be loaded.

            Folder:
            \(folderPath)

            Problems:
            \(bulletList)

            Choose a WhisperKit/Core ML folder that contains MelSpectrogram, AudioEncoder, and TextDecoder.
            """
        }
    }
}

private struct WhisperRuntimeConfiguration: Sendable {
    let modelName: String?
    let modelRepo: String?
    let modelFolderPath: String
    let tokenizerFolder: URL?
}
