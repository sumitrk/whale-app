import CoreML
import FluidAudio
import Foundation
import WhisperKit

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
    static let shared = TranscriptionModelStore(backends: .shared)

    @Published private(set) var installStates: [BuiltInModelID: NativeModelInstallState]
    /// The model being loaded into memory, once that has taken long enough to be worth showing.
    /// A warm load takes a tenth of a second; the first one after an install or an update
    /// compiles for the Neural Engine and can take 10+ seconds.
    @Published private(set) var preparingModelID: BuiltInModelID?
    private var prepareToken: UUID?

    private let backends: TranscriptionBackends
    private var activeOperations: [BuiltInModelID: ModelOperationContext] = [:]

    private typealias ModelOperation = @Sendable (ModelInstallProgressHandler?) async throws -> Void

    init(backends: TranscriptionBackends) {
        self.backends = backends
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
            let isInstalled = try await backends[modelID].isInstalled(modelID: modelID)
            setInstallState(isInstalled ? .ready : .notInstalled, for: modelID)
        } catch {
            setInstallState(.failed(error.localizedDescription), for: modelID)
        }
    }

    /// Makes `modelID` the one dictation uses and starts loading it, so the next dictation
    /// doesn't wait for it.
    func use(_ modelID: BuiltInModelID) {
        guard SettingsStore.shared.selectedBuiltInModelID != modelID else { return }
        SettingsStore.shared.selectedBuiltInModelID = modelID
        Task { try? await prepare(modelID) }
    }

    /// Loads the model into memory, showing it as preparing if that takes more than a moment.
    func prepare(_ modelID: BuiltInModelID) async throws {
        let token = UUID()
        prepareToken = token
        let reveal = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, self.prepareToken == token else { return }
            self.preparingModelID = modelID
        }
        defer {
            reveal.cancel()
            if prepareToken == token {
                prepareToken = nil
                preparingModelID = nil
            }
        }
        try await backends[modelID].prepare(modelID: modelID)
    }

    func install(_ modelID: BuiltInModelID) {
        guard !isDownloading(modelID) else { return }

        startModelOperation(
            modelID,
            initialState: .downloading(progress: nil, phase: "Preparing model download…"),
            successState: .ready
        ) { [backends] progressHandler in
            try await backends[modelID].install(modelID: modelID, progressHandler: progressHandler)
        }
    }

    func reset(_ modelID: BuiltInModelID) {
        guard !isDownloading(modelID) else { return }

        startModelOperation(
            modelID,
            initialState: .checking,
            successState: .notInstalled
        ) { [backends] _ in
            try await backends[modelID].resetModel(modelID: modelID)
        }
    }

    func connectLocalModel(_ modelID: BuiltInModelID, folderURL: URL) {
        guard !isDownloading(modelID) else { return }

        startModelOperation(
            modelID,
            initialState: .downloading(progress: nil, phase: "Validating local model folder…"),
            successState: .ready
        ) { [backends] progressHandler in
            try await backends[modelID].connectLocalModel(
                modelID: modelID,
                folderURL: folderURL,
                progressHandler: progressHandler
            )
        }
    }

    /// Abandons an install in flight and puts the row back where it was.
    ///
    /// What this stops depends on where the work has got to. A transfer is carried by
    /// URLSession and does stop; the Core ML compile that follows is not interruptible, so it
    /// runs itself out in the background while the install is discarded either way. Partly
    /// downloaded files are deliberately left alone — they let a retry resume rather than
    /// start over, and removing files is what Delete is for.
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
