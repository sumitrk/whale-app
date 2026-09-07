import Foundation

/// Install state for S1-mini, in the shape the Models pane already knows how to draw.
///
/// Deliberately not part of `TranscriptionModelStore`: that store's whole vocabulary —
/// selection, active model, language capability — belongs to the question of which engine
/// turns audio into text, and S1 does not answer it. Reusing only
/// `NativeModelInstallState` keeps the two panes consistent without conflating them.
@MainActor
final class CleanupModelStore: ObservableObject {
    static let shared = CleanupModelStore()

    @Published private(set) var installState: NativeModelInstallState = .checking

    private let installer: S1ModelInstaller
    private let engine: any TranscriptCleanupEngine
    private var operation: Task<Void, Never>?

    init(
        installer: S1ModelInstaller = .shared,
        engine: any TranscriptCleanupEngine = S1CleanupEngine.shared
    ) {
        self.installer = installer
        self.engine = engine
    }

    var isReady: Bool {
        if case .ready = installState { return true }
        return false
    }

    var isBusy: Bool {
        switch installState {
        case .downloading, .checking: return true
        case .ready, .notInstalled, .failed: return false
        }
    }

    func refresh() async {
        guard operation == nil else { return }
        installState = await installer.isInstalled() ? .ready : .notInstalled
    }

    func install() {
        guard !isDownloading else { return }

        installState = .downloading(progress: nil, phase: "Preparing model download…")
        operation = Task { [installer] in
            do {
                try await installer.install { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isDownloading else { return }
                        self.installState = .downloading(
                            progress: progress.fractionCompleted,
                            phase: progress.phase
                        )
                    }
                }
                guard !Task.isCancelled else { return }
                await self.finish(.ready)
            } catch {
                guard !Task.isCancelled else { return }
                await self.finish(.failed(error.localizedDescription))
            }
        }
    }

    /// Abandons the transfer and leaves the partial files alone, so a retry resumes
    /// rather than starting the 633 MB over. Clearing them is what Delete is for.
    func cancel() {
        guard let operation else { return }
        operation.cancel()
        self.operation = nil
        installState = .notInstalled
    }

    func remove() {
        guard !isDownloading else { return }

        installState = .checking
        operation = Task { [installer, engine] in
            // The weights cannot be deleted out from under a loaded model, and a model
            // held in memory would go on cleaning transcripts from files that no longer
            // exist — so the runtime is dropped first, not afterwards.
            await engine.unload()

            do {
                try await installer.remove()
                await self.finish(.notInstalled)
            } catch {
                await self.finish(.failed(error.localizedDescription))
            }
        }
    }

    /// Loads the model ahead of the first dictation that needs it. Cheap when the model is
    /// already resident, and the difference between a rewrite that feels instant and one
    /// that stalls behind a cold load when it is not.
    func warmIfReady() {
        guard isReady else { return }
        Task { [engine] in await engine.warm() }
    }

    private var isDownloading: Bool {
        if case .downloading = installState { return true }
        return false
    }

    private func finish(_ state: NativeModelInstallState) {
        installState = state
        operation = nil
    }
}
