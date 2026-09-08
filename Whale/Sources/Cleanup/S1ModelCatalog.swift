import Foundation
import Hub

/// Where S1-mini comes from and where it lands.
///
/// The MLX 8-bit conversion rather than the BF16 original: the app already targets Apple
/// Silicon, MLX loads the quantized weights directly, and it halves both the download and
/// the resident footprint at no measurable cost on a normalization task.
enum S1ModelCatalog {

    /// "S1-mini" by "Superwhisper", with that exact capitalization, is a term of the
    /// model's licence rather than a house style choice — it has to survive anywhere the
    /// model is named, including here.
    static let displayName = "S1-mini by Superwhisper"

    static let repositoryID = "mlx-community/S1-mini-MLX-8bit"

    /// Pinned. A silent upstream reconvert would otherwise change how every dictation
    /// reads, with nothing in the app to attribute it to.
    static let revision = "main"

    /// Weights, config and tokenizer. Nothing else in the repo is needed at runtime.
    static let filePatterns = ["*.safetensors", "*.json", "*.jinja"]

    static let approximateDownloadSize = "633 MB"

    /// The files whose absence means "not installed". A partial download leaves the
    /// directory in place — deliberately, so a retry resumes — so existence of the
    /// folder proves nothing on its own.
    static let requiredFiles = ["config.json", "model.safetensors", "tokenizer.json"]

    /// Hub materializes a snapshot at `<downloadBase>/models/<repo id>`, so pointing the
    /// base at Whale's own Models folder puts S1 beside Parakeet and Whisper — one place
    /// to look, one place to clear.
    static func downloadBase(_ runtimeInfo: AppRuntimeInfo) -> URL {
        runtimeInfo.modelsDirectoryURL
    }

    static func modelDirectory(_ runtimeInfo: AppRuntimeInfo) -> URL {
        downloadBase(runtimeInfo)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(repositoryID, isDirectory: true)
    }

    static func isInstalled(_ runtimeInfo: AppRuntimeInfo) -> Bool {
        let directory = modelDirectory(runtimeInfo)
        return requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }
}

/// Downloads and removes the S1-mini snapshot.
///
/// Separate from `LocalTranscriptionService`'s backends rather than folded into them:
/// those model that catalog's central question — which engine turns audio into text — and
/// S1 answers a different one. Sharing `NativeModelInstallState` gives the settings pane
/// one vocabulary for install progress without pretending this is a fourth transcriber.
actor S1ModelInstaller {
    static let shared = S1ModelInstaller()

    private let runtimeInfoProvider: @Sendable () -> AppRuntimeInfo

    init(runtimeInfoProvider: @escaping @Sendable () -> AppRuntimeInfo = { AppRuntimeInfo.current }) {
        self.runtimeInfoProvider = runtimeInfoProvider
    }

    var modelDirectory: URL {
        S1ModelCatalog.modelDirectory(runtimeInfoProvider())
    }

    func isInstalled() -> Bool {
        S1ModelCatalog.isInstalled(runtimeInfoProvider())
    }

    func install(progressHandler: ModelInstallProgressHandler?) async throws {
        let runtimeInfo = runtimeInfoProvider()
        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: "Resolving model storage…"))

        try FileManager.default.createDirectory(
            at: runtimeInfo.modelsDirectoryURL,
            withIntermediateDirectories: true
        )

        // `cache: nil` turns off Hub's shared content-addressed store under
        // `~/.cache/huggingface`. With it on, the 633 MB lands twice — once there and once
        // in the snapshot below — and Delete can only reach the copy Whale put down, so the
        // pane would report the space reclaimed while most of it was still on disk.
        // Resume still works: the part-files live beside the snapshot.
        let hub = HubApi(
            downloadBase: S1ModelCatalog.downloadBase(runtimeInfo),
            cache: nil
        )

        Self.log("Downloading \(S1ModelCatalog.repositoryID) to \(S1ModelCatalog.modelDirectory(runtimeInfo).path)")

        _ = try await hub.snapshot(
            from: S1ModelCatalog.repositoryID,
            revision: S1ModelCatalog.revision,
            matching: S1ModelCatalog.filePatterns
        ) { progress in
            progressHandler?(
                ModelInstallProgress(
                    fractionCompleted: progress.fractionCompleted,
                    phase: "Downloading model files"
                )
            )
        }

        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: "Validating model files…"))

        guard S1ModelCatalog.isInstalled(runtimeInfo) else {
            throw S1ModelInstallError.incompleteDownload
        }

        Self.log("Installed \(S1ModelCatalog.repositoryID)")
    }

    func remove() async throws {
        let directory = S1ModelCatalog.modelDirectory(runtimeInfoProvider())
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
        Self.log("Removed \(directory.path)")
    }

    private static func log(_ message: String) {
        let line = "[S1-mini] \(message)"
        print(line)
        DiagnosticLog.log(line)
    }
}

enum S1ModelInstallError: LocalizedError {
    case incompleteDownload

    var errorDescription: String? {
        switch self {
        case .incompleteDownload:
            return "The download finished but some S1-mini files are missing. Try again."
        }
    }
}
