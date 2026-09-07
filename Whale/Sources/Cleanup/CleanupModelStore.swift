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
    private let settings: SettingsStore
    private var operation: Task<Void, Never>?

    init(
        installer: S1ModelInstaller = .shared,
        engine: any TranscriptCleanupEngine = S1CleanupEngine.shared,
        settings: SettingsStore = .shared
    ) {
        self.installer = installer
        self.engine = engine
        self.settings = settings
    }

    var isReady: Bool {
        if case .ready = installState { return true }
        return false
    }

    /// Whether there is anything on disk worth showing a row for — which is every state
    /// except the one that means "nothing here". Kept deliberately loose: `.checking`
    /// counts so the row does not flash out of existence on every appearance, and
    /// `.failed` counts because a failed download leaves part-files a Delete can reclaim.
    var isInstalled: Bool {
        if case .notInstalled = installState { return false }
        return true
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

    /// The switch is the download. Cleanup ships on, so on a first launch this is what
    /// fetches the weights without anyone visiting the Models pane; flipping the toggle
    /// back on later lands here too.
    ///
    /// A failed state is left alone rather than retried on sight — a download that just
    /// failed would otherwise re-fail every time the pane is opened, with the Retry
    /// button never getting a turn.
    func installIfNeeded() async {
        guard settings.transcriptCleanupEnabled else { return }
        await refresh()
        guard case .notInstalled = installState else { return }
        install()
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
    ///
    /// Switches Cleanup off as well. Without that, `installIfNeeded` would start the
    /// download again on the next launch or the next time the pane is opened, and Cancel
    /// would amount to a pause the user never asked for.
    func cancel() {
        guard let operation else { return }
        operation.cancel()
        self.operation = nil
        settings.transcriptCleanupEnabled = false
        installState = .notInstalled
    }

    /// Deleting the weights switches Cleanup off, because the alternative is a toggle that
    /// reads as on while every dictation quietly bypasses it. Switching it off does *not*
    /// delete anything — this is the only path that removes the 633 MB, and it is always
    /// something the user asked for by name.
    func remove() {
        guard !isDownloading else { return }

        settings.transcriptCleanupEnabled = false
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
