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

/// Which box a model lives in on the Models settings pane: models Whale ships and can
/// install itself, versus a checkpoint the user points at on disk.
enum BuiltInModelSource: String, Codable, CaseIterable, Sendable {
    case bundled
    case custom
}

struct BuiltInModelDescriptor: Identifiable, Equatable, Sendable {
    let id: BuiltInModelID
    let group: BuiltInModelGroup
    let source: BuiltInModelSource
    let provisioning: BuiltInModelProvisioning
    let title: String
    /// Short capability blurb shown after the status while the row has no language control —
    /// before install, and while it needs attention. Once a language control appears it says
    /// the same thing more precisely, so the two are never shown at once.
    let capabilityLabel: String
    /// What this model can decode, for models whose checkpoint we pin. `unknown` means the
    /// answer has to be measured when the model loads, which is only true of a folder the
    /// user supplied.
    let declaredLanguageCapability: ModelLanguageCapability
    let detail: String
    let markdownLabel: String

    var installationPrompt: String {
        switch provisioning {
        case .download:
            return "\(title) is not downloaded. Open Settings > Models and download it."
        case .localFolder:
            return "\(title) is not configured yet. Open Settings > Models, choose a WhisperKit/Core ML folder, and try again."
        }
    }

    var actionTitle: String {
        switch provisioning {
        case .download:
            return "Download"
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

    /// Whether the app put these files on disk and may therefore take them off again.
    ///
    /// Derived from how the model is provisioned rather than listed per model, so the question
    /// "may we delete this?" can never be answered wrongly for a model added later: anything
    /// the app downloads it owns, anything the user points it at belongs to the user.
    var ownsModelFiles: Bool {
        switch provisioning {
        case .download:    return true
        case .localFolder: return false
        }
    }

    /// Named for what it does rather than for the cache-clearing it used to imply — the next
    /// use has to download the model again.
    ///
    /// A folder the user converted themselves is only forgotten, never erased, and the wording
    /// has to say so; the two come from one property so they cannot drift apart.
    var resetActionTitle: String? {
        ownsModelFiles ? "Delete" : "Disconnect"
    }
}

enum BuiltInModelCatalog {
    static let allModels: [BuiltInModelDescriptor] = [
        BuiltInModelDescriptor(
            id: .parakeetEnglishV2,
            group: .parakeet,
            source: .bundled,
            provisioning: .download,
            title: "Parakeet",
            capabilityLabel: "English only",
            declaredLanguageCapability: .single(code: "en"),
            detail: "Parakeet TDT v2 • English only • Runs locally on-device",
            markdownLabel: "FluidAudio Parakeet v2"
        ),
        BuiltInModelDescriptor(
            id: .whisperLargeV3Turbo,
            group: .whisper,
            source: .bundled,
            provisioning: .download,
            title: "Whisper Large v3 Turbo",
            capabilityLabel: "Multilingual",
            declaredLanguageCapability: .multilingual,
            detail: "WhisperKit • OpenAI Whisper large-v3-turbo • Runs locally on-device",
            markdownLabel: "Whisper Large V3 Turbo"
        ),
        BuiltInModelDescriptor(
            id: .whisperLocalFolder,
            group: .whisper,
            source: .custom,
            provisioning: .localFolder,
            title: "Local Whisper Folder",
            // The folder is whatever the user picked, so we can only promise detection,
            // not multilingual support: an English-only checkpoint is a valid choice here.
            capabilityLabel: "Auto-detect",
            // Measured the first time the folder loads, then remembered. Until then the row
            // shows no language control rather than guessing at one.
            declaredLanguageCapability: .unknown,
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

    static func models(from source: BuiltInModelSource) -> [BuiltInModelDescriptor] {
        allModels.filter { $0.source == source }
    }
}

/// The one-line state a model row reports. Deliberately separate from
/// `NativeModelInstallState`: install state is about the bytes on disk, this is what the
/// settings row says, which also folds in whether the model is the selected one.
enum TranscriptionModelStatus: Equatable {
    /// Selected for transcription. The download action can still be shown when its files are missing.
    case active
    /// Installed but not selected.
    case inactive
    case notInstalled
    /// A download, validation, or cache check is in flight. Carries the phase text.
    case working(String)
    case needsAttention

    var text: String {
        switch self {
        case .active:              return "Active"
        case .inactive:            return "Inactive"
        case .notInstalled:        return "Not Installed"
        case .working(let phase):  return phase
        case .needsAttention:      return "Needs Attention"
        }
    }

    /// Transient work gets a spinner in the row's trailing slot instead of a status dot.
    var showsDot: Bool {
        if case .working = self { return false }
        return true
    }
}

struct TranscriptionModelRowModel: Equatable {
    let status: TranscriptionModelStatus
    let primaryActionTitle: String?
    let progress: Double?
    let isBusy: Bool
    let errorText: String?
    let resetActionTitle: String?
    let isReady: Bool

    var statusText: String { status.text }

    /// The language belongs in exactly one place per row. A row showing a language control
    /// says it there, precisely, so repeating the capability blurb beside the status would
    /// only be redundant — and, next to a control reading "Auto-detect", faintly contradictory.
    /// A row without one keeps the blurb, because before install it is the only way to learn
    /// that Whisper is worth its download.
    ///
    /// While a download or check is running the phase text is the whole story.
    func statusLine(capabilityLabel: String, hasLanguageControl: Bool) -> String {
        if case .working = status {
            return statusText
        }

        guard !hasLanguageControl else { return statusText }
        return "\(statusText) · \(capabilityLabel)"
    }

    init(
        model: BuiltInModelDescriptor,
        installState: NativeModelInstallState,
        isSelected: Bool
    ) {
        switch installState {
        case .checking:
            status = .working("Checking…")
            primaryActionTitle = nil
            progress = nil
            isBusy = true
            errorText = nil
            resetActionTitle = nil
            isReady = false

        case .notInstalled:
            // Keep the selected row visually active even before its files are downloaded. The
            // Download action makes the next step clear without turning a missing model into
            // an error state.
            status = isSelected ? .active : .notInstalled
            primaryActionTitle = model.actionTitle
            progress = nil
            isBusy = false
            errorText = nil
            resetActionTitle = nil
            isReady = false

        case .downloading(let fraction, let phase):
            let percent = fraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            status = .working(phase + percent)
            primaryActionTitle = nil
            progress = fraction
            isBusy = true
            errorText = nil
            resetActionTitle = nil
            isReady = false

        case .ready:
            // A model only reads "Active" while it is genuinely usable. Selection is never
            // reassigned behind the user's back, so an uninstalled-but-selected model just
            // reads "Not Installed" and nothing in the list claims to be active.
            status = isSelected ? .active : .inactive
            primaryActionTitle = model.changeActionTitle
            progress = nil
            isBusy = false
            errorText = nil
            resetActionTitle = model.resetActionTitle
            isReady = true

        case .failed(let message):
            status = .needsAttention
            primaryActionTitle = model.retryActionTitle
            progress = nil
            isBusy = false
            errorText = message
            resetActionTitle = model.resetActionTitle
            isReady = false
        }
    }
}

enum WhisperBuiltInConfiguration {
    static let modelRepo = "argmaxinc/whisperkit-coreml"
    static let modelVariant = "openai_whisper-large-v3_turbo"

    /// Core ML compiles the model for this Mac the first time it loads, out of process and for
    /// minutes on the large checkpoints — the app itself sits idle at 0% CPU throughout. Left
    /// to say only "Loading model…" the row looks wedged, so the wait is named up front.
    static let loadingPhase = "Optimizing model for this Mac — first run takes a few minutes"

    /// `nil` means the user left the model on Auto-detect, and the language is worked out
    /// from the audio. Naming a language turns detection off rather than merely biasing it:
    /// on the short clips this app records, detection has less to go on than the user does.
    static func decodingOptions(language: String? = nil) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0.0,
            detectLanguage: language == nil,
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

private final class ModelOperationContext {
    let id: UUID
    let previousState: NativeModelInstallState
    var task: Task<Void, Never>?

    init(id: UUID, previousState: NativeModelInstallState) {
        self.id = id
        self.previousState = previousState
    }
}

@MainActor
final class TranscriptionModelStore: ObservableObject {
    static let shared = TranscriptionModelStore(service: .shared)

    @Published private(set) var installStates: [BuiltInModelID: NativeModelInstallState]

    private let service: LocalTranscriptionService
    private var activeOperations: [BuiltInModelID: ModelOperationContext] = [:]

    private typealias ModelOperation = @Sendable (ModelInstallProgressHandler?) async throws -> Void

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
        guard activeOperations.isEmpty else { return }
        Task { await refreshNow() }
    }

    func refreshNow() async {
        for model in BuiltInModelCatalog.allModels {
            await refresh(model.id)
        }
    }

    func refresh(_ modelID: BuiltInModelID) async {
        guard activeOperations[modelID] == nil else { return }

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

        startModelOperation(
            modelID,
            initialState: .downloading(progress: nil, phase: "Preparing model download…"),
            successState: .ready
        ) { [service] progressHandler in
            try await service.installModel(modelID, progressHandler: progressHandler)
        }
    }

    func reset(_ modelID: BuiltInModelID) {
        guard !isDownloading(modelID) else { return }

        startModelOperation(
            modelID,
            initialState: .checking,
            successState: .notInstalled
        ) { [service] _ in
            try await service.resetModel(modelID)
        }
    }

    func connectLocalModel(_ modelID: BuiltInModelID, folderURL: URL) {
        guard !isDownloading(modelID) else { return }

        startModelOperation(
            modelID,
            initialState: .downloading(progress: nil, phase: "Validating local model folder…"),
            successState: .ready
        ) { [service] progressHandler in
            try await service.connectLocalModel(
                modelID,
                folderURL: folderURL,
                progressHandler: progressHandler
            )
        }
    }

    func cancel(_ modelID: BuiltInModelID) {
        cancelModelOperation(modelID)
    }

    private func startModelOperation(
        _ modelID: BuiltInModelID,
        initialState: NativeModelInstallState,
        successState: NativeModelInstallState,
        operation: @escaping ModelOperation
    ) {
        cancelModelOperation(modelID)

        let context = ModelOperationContext(
            id: UUID(),
            previousState: installState(for: modelID)
        )
        activeOperations[modelID] = context
        setInstallState(initialState, for: modelID)

        let operationID = context.id
        context.task = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.finishModelOperation(modelID, operationID: operationID)
                }
            }

            do {
                try await operation { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrentModelOperation(modelID, operationID: operationID) else {
                            return
                        }
                        self.setInstallState(
                            .downloading(
                                progress: progress.fractionCompleted,
                                phase: progress.phase
                            ),
                            for: modelID
                        )
                    }
                }

                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.completeModelOperation(
                        modelID,
                        operationID: operationID,
                        state: successState
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.completeModelOperation(
                        modelID,
                        operationID: operationID,
                        state: .failed(error.localizedDescription)
                    )
                }
            }
        }
    }

    private func cancelModelOperation(_ modelID: BuiltInModelID) {
        guard let context = activeOperations.removeValue(forKey: modelID) else { return }
        context.task?.cancel()
        setInstallState(cancellationState(for: context.previousState), for: modelID)
    }

    private func cancellationState(for state: NativeModelInstallState) -> NativeModelInstallState {
        if case .checking = state {
            return .notInstalled
        }
        return state
    }

    private func isCurrentModelOperation(_ modelID: BuiltInModelID, operationID: UUID) -> Bool {
        activeOperations[modelID]?.id == operationID
    }

    private func completeModelOperation(
        _ modelID: BuiltInModelID,
        operationID: UUID,
        state: NativeModelInstallState
    ) {
        guard isCurrentModelOperation(modelID, operationID: operationID) else { return }
        setInstallState(state, for: modelID)
        finishModelOperation(modelID, operationID: operationID)
    }

    private func finishModelOperation(_ modelID: BuiltInModelID, operationID: UUID) {
        guard isCurrentModelOperation(modelID, operationID: operationID) else { return }
        activeOperations[modelID] = nil
    }

    private func isDownloading(_ modelID: BuiltInModelID) -> Bool {
        if case .downloading = installState(for: modelID) {
            return true
        }
        return false
    }

    /// The selection is never reassigned when a model stops being ready. Silently swapping
    /// the transcription engine underneath the user is more surprising than a Models pane
    /// where nothing reads "Active" until they reinstall or pick another model.
    private func setInstallState(_ state: NativeModelInstallState, for modelID: BuiltInModelID) {
        installStates[modelID] = state
    }
}

protocol BuiltInTranscriptionBackend: Sendable {
    func isInstalled(modelID: BuiltInModelID) async throws -> Bool
    func prepare(modelID: BuiltInModelID) async throws
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
    func prepare(modelID: BuiltInModelID) async throws {
        throw LocalTranscriptionError.unsupportedModel(modelID)
    }

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

    func prepareModel(_ modelID: BuiltInModelID) async throws {
        try await backend(for: modelID).prepare(modelID: modelID)
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
    /// Chunked, disk-backed pass over the file. Constant memory regardless of length,
    /// and a different decode path than `transcribe`, so it doubles as the retry when
    /// the in-memory pass comes back empty.
    func transcribeDiskBacked(_ wavURL: URL, source: AudioSource) async throws -> String
}

protocol ParakeetModelRuntime: Sendable {
    func modelsExist(at modelDirectory: URL) async -> Bool
    func downloadModels(
        to modelDirectory: URL,
        progressHandler: ProgressHandler?
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
        progressHandler: ProgressHandler?
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

actor ParakeetTranscriptionBackend: BuiltInTranscriptionBackend {
    private let runtime: any ParakeetModelRuntime
    private let runtimeInfoProvider: @Sendable () -> AppRuntimeInfo
    private var manager: (any ParakeetManaging)?
    private var loadedModelDirectory: URL?
    private var hasCheckedLegacyModelDirectory = false

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

        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: "Validating model files…"))

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

        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: "Preparing model for first use…"))

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

    private func modelContext(for modelID: BuiltInModelID) throws -> (runtimeInfo: AppRuntimeInfo, modelDirectory: URL) {
        guard case .parakeetEnglishV2 = modelID else {
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }

        let runtimeInfo = runtimeInfoProvider()
        adoptLegacyModelDirectoryIfNeeded(for: runtimeInfo)

        return (
            runtimeInfo: runtimeInfo,
            modelDirectory: runtimeInfo.parakeetEnglishV2DirectoryURL
        )
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

        do {
            _ = try Self.validateStoredModelFolder(
                for: modelID,
                modelURL: modelURL
            )
            return true
        } catch LocalTranscriptionError.invalidWhisperModelFolder {
            // A stale or partial WhisperKit folder is equivalent to no downloaded model from
            // the settings pane's perspective. Let the row offer Download instead of exposing
            // the validation details as a red error card.
            return false
        }
    }

    func prepare(modelID: BuiltInModelID) async throws {
        _ = try await ensureReady(modelID: modelID)
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
        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: WhisperBuiltInConfiguration.loadingPhase))
        let validation = try Self.validateStoredModelFolder(for: modelID, modelURL: modelFolder)
        _ = try await prepareWhisperKit(
            modelID: modelID,
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
        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: WhisperBuiltInConfiguration.loadingPhase))
        _ = try await prepareWhisperKit(
            modelID: modelID,
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
            decodeOptions: WhisperBuiltInConfiguration.decodingOptions(
                language: await resolvedLanguageCode(for: modelID)
            )
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
            modelID: modelID,
            runtime: Self.runtimeConfiguration(for: modelID, validation: validation)
        )
    }

    private func prepareWhisperKit(
        modelID: BuiltInModelID,
        runtime: WhisperRuntimeConfiguration,
        forceReload: Bool = false
    ) async throws -> WhisperKit {
        if !forceReload, let whisperKit, loadedModelPath == runtime.modelFolderPath {
            await recordLanguageCapability(of: whisperKit, for: modelID)
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
        await recordLanguageCapability(of: whisperKit, for: modelID)
        return whisperKit
    }

    /// Loading is the only moment the truth about a folder is available: WhisperKit reads the
    /// decoder's output dimension and knows whether the checkpoint carries language tokens.
    /// Recording it on every load rather than only at connect time is what lets a folder
    /// attached by an earlier build grow its language control the first time it is dictated
    /// into, instead of demanding the user re-pick a folder that was never wrong.
    private func recordLanguageCapability(
        of whisperKit: WhisperKit,
        for modelID: BuiltInModelID
    ) async {
        // Whisper's non-multilingual checkpoints are the `.en` variants, which are English by
        // construction — there is no other single-language Whisper to confuse this with.
        let capability: ModelLanguageCapability = whisperKit.modelVariant.isMultilingual
            ? .multilingual
            : .single(code: "en")

        await MainActor.run {
            SettingsStore.shared.setDetectedLanguageCapability(capability, for: modelID)
        }
    }

    /// Deleting is for the checkpoint the app downloaded; the folder the user chose is only
    /// forgotten. Both drop the loaded instance and the measured capability, because the next
    /// folder behind that row need not speak the same languages as the last.
    func resetModel(modelID: BuiltInModelID) async throws {
        guard modelID.descriptor.group == .whisper else {
            throw LocalTranscriptionError.unsupportedModel(modelID)
        }

        let modelURL = await persistedModelURL(for: modelID)

        whisperKit = nil
        loadedModelPath = nil

        // A folder that is already gone is the state Delete was asking for, so do not turn it
        // into an error the row has to display.
        if modelID.descriptor.ownsModelFiles,
           let modelURL,
           FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.removeItem(at: modelURL)
        }

        await MainActor.run {
            SettingsStore.shared.setLocalModelPath(nil, for: modelID)
            SettingsStore.shared.setDetectedLanguageCapability(.unknown, for: modelID)
        }
    }

    private func resolvedLanguageCode(for modelID: BuiltInModelID) async -> String? {
        await MainActor.run {
            ModelLanguageResolver.decodingLanguageCode(
                for: modelID.descriptor,
                detected: SettingsStore.shared.detectedLanguageCapability(for: modelID),
                storedCode: SettingsStore.shared.languageCode(for: modelID)
            )
        }
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

            Use Delete in Settings > Models, then install Parakeet again.
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
