import CoreML
import FluidAudio
import Foundation
import WhisperKit

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

protocol ParakeetManaging: Sendable {
    func transcribe(_ wavURL: URL, source: AudioSource) async throws -> String
    /// Chunked, disk-backed pass over the file. Constant memory regardless of length,
    /// and a different decode path than `transcribe`, so it doubles as the retry when
    /// the in-memory pass comes back empty.
    func transcribeDiskBacked(_ wavURL: URL, source: AudioSource) async throws -> String
}

/// One Parakeet-family checkpoint: where its files come from and how FluidAudio loads them.
protocol ParakeetModelRuntime: Sendable {
    func modelsExist(at modelDirectory: URL) async -> Bool
    func downloadModels(
        to modelDirectory: URL,
        progressHandler: ModelInstallProgressHandler?
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
        progressHandler: ModelInstallProgressHandler?
    ) async throws {
        _ = try await AsrModels.download(
            to: modelDirectory,
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
    }

    private static func phaseLabel(for phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Looking up model files…"
        case .downloading(let completedFiles, let totalFiles):
            return "Downloading model files \(completedFiles)/\(totalFiles)"
        case .compiling(let modelName):
            return "Compiling \(modelName)…"
        }
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

        return try await Self.makeManager(models: models, modelDirectory: modelDirectory)
    }

    /// Shared by every Parakeet-family checkpoint once its models are loaded.
    static func makeManager(models: AsrModels, modelDirectory: URL) async throws -> any ParakeetManaging {
        let manager = AsrManager(config: .default)

        do {
            try await manager.loadModels(models)
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

    /// `source` no longer reaches FluidAudio. It used to pick between two decoder states
    /// the manager held internally, but both were reset after every call, so each
    /// transcription already started from zero. A fresh state per call is the same thing,
    /// stated directly.
    func transcribe(_ wavURL: URL, source _: AudioSource) async throws -> String {
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(wavURL, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribeDiskBacked(_ wavURL: URL, source _: AudioSource) async throws -> String {
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribeDiskBacked(wavURL, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Every Parakeet-family checkpoint. Only one is held in memory at a time: switching models
/// drops the loaded one, because the folder it came from no longer matches.
actor ParakeetTranscriptionBackend: BuiltInTranscriptionBackend {
    private let runtimes: [BuiltInModelID: any ParakeetModelRuntime]
    private let runtimeInfoProvider: @Sendable () -> AppRuntimeInfo
    private var manager: (any ParakeetManaging)?
    private var loadedModelDirectory: URL?
    /// The load in flight, so callers arriving while it runs wait for it instead of starting
    /// their own. The actor yields at every `await`, and a first load can spend 10+ seconds
    /// compiling for the Neural Engine — without this, launch, a model switch and a dictation
    /// each began a separate compile of the same model.
    private var pendingLoad: (directory: URL, task: Task<any ParakeetManaging, Error>)?
    private var hasCheckedLegacyModelDirectory = false

    init(
        runtimes: [BuiltInModelID: any ParakeetModelRuntime] = [
            .parakeetEnglishV2: FluidAudioParakeetRuntime(),
            .barkCleanEnglish: BarkCleanParakeetRuntime(),
        ],
        runtimeInfoProvider: @escaping @Sendable () -> AppRuntimeInfo = { AppRuntimeInfo.current }
    ) {
        self.runtimes = runtimes
        self.runtimeInfoProvider = runtimeInfoProvider
    }

    func isInstalled(modelID: BuiltInModelID) async throws -> Bool {
        let context = try modelContext(for: modelID)
        Self.log("Checking install state at \(context.modelDirectory.path) (\(context.runtimeInfo.storageDescription))")

        guard await context.runtime.modelsExist(at: context.modelDirectory) else {
            Self.log("Model files missing at \(context.modelDirectory.path)")
            return false
        }

        Self.log("Found model files at \(context.modelDirectory.path)")
        return true
    }

    func prepare(modelID: BuiltInModelID) async throws {
        try await ensureReady(modelID: modelID)
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
            try await context.runtime.downloadModels(
                to: context.modelDirectory,
                progressHandler: progressHandler
            )
        } catch {
            Self.log("Download failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .downloading,
                modelDirectory: context.modelDirectory.path
            )
        }

        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: "Validating model files…"))

        guard await context.runtime.modelsExist(at: context.modelDirectory) else {
            let reason = "Expected Parakeet model files were not found after download."
            Self.log("Validation failed at \(context.modelDirectory.path): \(reason)")
            throw LocalTranscriptionError.parakeetSetupFailed(
                step: .validatingFiles,
                modelDirectory: context.modelDirectory.path,
                reason: reason
            )
        }

        do {
            try await context.runtime.validateModels(at: context.modelDirectory)
        } catch {
            Self.log("Validation failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .validatingFiles,
                modelDirectory: context.modelDirectory.path
            )
        }

        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: "Preparing model for first use…"))

        do {
            manager = try await context.runtime.prepareManager(at: context.modelDirectory)
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

            Self.log("Standard transcription returned empty text at \(context.modelDirectory.path); retrying disk-backed")
        } catch {
            Self.log("Standard transcription failed at \(context.modelDirectory.path): \(error.localizedDescription)")
        }

        do {
            return try await manager.transcribeDiskBacked(wavURL, source: source)
        } catch {
            Self.log("Disk-backed transcription failed at \(context.modelDirectory.path): \(error.localizedDescription)")
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
        // Deleting one checkpoint shouldn't unload another that's still in use.
        if loadedModelDirectory == context.modelDirectory {
            manager = nil
            loadedModelDirectory = nil
        }
        if pendingLoad?.directory == context.modelDirectory {
            pendingLoad?.task.cancel()
            pendingLoad = nil
        }

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

        if let pendingLoad, pendingLoad.directory == context.modelDirectory {
            Self.log("Waiting for the model load already running at \(context.modelDirectory.path)")
            manager = try await pendingLoad.task.value
            loadedModelDirectory = context.modelDirectory
            return
        }

        Self.log("Ensuring model runtime is ready at \(context.modelDirectory.path)")

        // Registered before anything else awaits, so a caller arriving during the file check
        // joins this load rather than starting a second one.
        let runtime = context.runtime
        let directory = context.modelDirectory
        let descriptor = modelID.descriptor
        let load = Task {
            guard await runtime.modelsExist(at: directory) else {
                throw LocalTranscriptionError.modelNotInstalled(descriptor)
            }
            return try await runtime.prepareManager(at: directory)
        }
        pendingLoad = (directory, load)
        defer {
            if pendingLoad?.directory == directory { pendingLoad = nil }
        }

        do {
            let started = Date()
            manager = try await load.value
            loadedModelDirectory = directory
            Self.log("Model runtime ready in \(String(format: "%.1f", Date().timeIntervalSince(started)))s at \(directory.path)")
        } catch {
            Self.log("Runtime preparation failed at \(context.modelDirectory.path): \(error.localizedDescription)")
            throw Self.wrapError(
                error,
                step: .preparingRuntime,
                modelDirectory: context.modelDirectory.path
            )
        }
    }

    private func modelContext(
        for modelID: BuiltInModelID
    ) throws -> (runtimeInfo: AppRuntimeInfo, modelDirectory: URL, runtime: any ParakeetModelRuntime) {
        guard let runtime = runtimes[modelID] else {
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }

        let runtimeInfo = runtimeInfoProvider()
        let modelDirectory: URL
        switch modelID {
        case .barkCleanEnglish:
            modelDirectory = runtimeInfo.barkCleanDirectoryURL
        default:
            adoptLegacyModelDirectoryIfNeeded(for: runtimeInfo)
            modelDirectory = runtimeInfo.parakeetEnglishV2DirectoryURL
        }

        return (runtimeInfo: runtimeInfo, modelDirectory: modelDirectory, runtime: runtime)
    }

    /// Move a pre-0.15 install onto the folder name FluidAudio now derives, so upgrading
    /// adopts the ~440 MB already on disk instead of re-downloading it and orphaning the old
    /// copy. Runs at most once per backend instance, and only when there is something to move.
    private func adoptLegacyModelDirectoryIfNeeded(for runtimeInfo: AppRuntimeInfo) {
        guard !hasCheckedLegacyModelDirectory else { return }
        hasCheckedLegacyModelDirectory = true

        let fileManager = FileManager.default
        let legacy = runtimeInfo.legacyParakeetEnglishV2DirectoryURL
        let current = runtimeInfo.parakeetEnglishV2DirectoryURL

        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: current.path)
        else { return }

        do {
            try fileManager.moveItem(at: legacy, to: current)
            Self.log("Adopted legacy model install \(legacy.lastPathComponent) → \(current.lastPathComponent)")
        } catch {
            // Not fatal: the install path below will just download a fresh copy.
            Self.log("Could not adopt legacy model install at \(legacy.path): \(error.localizedDescription)")
        }
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
