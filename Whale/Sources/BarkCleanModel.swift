import CoreML
import CryptoKit
import FluidAudio
import Foundation

/// Underdog Bark 3.0 Clean: a Parakeet TDT v3 fine-tune that leaves out "um", false starts and
/// repeated words as it transcribes.
///
/// Underdog publishes it in their own entropy-coded `.bark` format, which only their Python
/// loader reads, so Whale downloads a Core ML conversion of it instead (made by
/// `tools/bark-spike/convert_bark.py`) that we host on R2. The conversion is laid out the way
/// FluidAudio's own v3 folder is — Preprocessor, Encoder, Decoder, JointDecisionv3 and the
/// vocabulary — so FluidAudio runs it unchanged. CC-BY-4.0: see
/// `Whale/Resources/Licenses/Bark-3.0-Clean/`.
enum BarkCleanModelCatalog {
    static let displayName = "Bark 3.0 Clean"

    /// Bump the `v1` in both the folder and the URL together when a new conversion ships, so
    /// an old install is never mistaken for the new one.
    static let directoryName = "bark-3.0-clean-coreml-v1"
    static let archiveURL = URL(
        string: "https://pub-a6988c76db684687b1f5d2ce4549daa6.r2.dev/bark-3.0-clean/v1/bark-3.0-clean-coreml-v1.tar.xz"
    )!
    static let archiveByteCount: Int64 = 280_623_920
    static let archiveSHA256 = "3c829468ab53958644ae44a2a3086338aabefd92dfa6fcc871983d0a2702b459"

    /// Every file `AsrModels.loadLocal(version: .v3)` opens. A folder missing any of them is
    /// treated as not installed rather than half-installed.
    static let requiredFiles = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecisionv3.mlmodelc",
        "parakeet_vocab.json",
    ]
}

/// Bark through FluidAudio, from a folder Whale fills itself.
///
/// FluidAudio's own `AsrModels.load(from:)` is no use here: it ignores the folder it is given
/// and resolves `<parent>/<FluidAudio's folder for the version>`, downloading stock v3 into
/// it if that is missing. `loadLocal(from:)` reads exactly the folder named.
struct BarkCleanParakeetRuntime: ParakeetModelRuntime {
    func modelsExist(at modelDirectory: URL) async -> Bool {
        BarkCleanModelCatalog.requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent($0).path)
        }
    }

    /// Downloads to a temporary file, checks it against the pinned size and SHA-256, unpacks
    /// beside the final folder and only then moves it into place, so a cancelled or failed
    /// install never leaves a folder that looks complete.
    func downloadModels(
        to modelDirectory: URL,
        progressHandler: ModelInstallProgressHandler?
    ) async throws {
        let fileManager = FileManager.default
        let parent = modelDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        progressHandler?(ModelInstallProgress(fractionCompleted: 0, phase: "Downloading \(BarkCleanModelCatalog.displayName)"))
        let archive = try await ModelArchiveDownload.download(
            from: BarkCleanModelCatalog.archiveURL,
            expectedByteCount: BarkCleanModelCatalog.archiveByteCount
        ) { fraction in
            progressHandler?(ModelInstallProgress(
                fractionCompleted: fraction,
                phase: "Downloading \(BarkCleanModelCatalog.displayName)"
            ))
        }
        defer { try? fileManager.removeItem(at: archive) }
        try Task.checkCancellation()

        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: "Verifying download…"))
        let digest = try Self.sha256(of: archive)
        guard digest == BarkCleanModelCatalog.archiveSHA256 else {
            throw BarkCleanModelError.checksumMismatch(expected: BarkCleanModelCatalog.archiveSHA256, actual: digest)
        }
        try Task.checkCancellation()

        progressHandler?(ModelInstallProgress(fractionCompleted: nil, phase: "Unpacking model files…"))
        let staging = parent.appendingPathComponent(".\(BarkCleanModelCatalog.directoryName)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        try await Self.untar(archive, into: staging)

        guard await modelsExist(at: staging) else {
            throw BarkCleanModelError.incompleteArchive
        }
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: modelDirectory.path) {
            try fileManager.removeItem(at: modelDirectory)
        }
        try fileManager.moveItem(at: staging, to: modelDirectory)
    }

    func validateModels(at modelDirectory: URL) async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        _ = try AsrModels.loadLocal(from: modelDirectory, version: .v3, configuration: configuration)
    }

    func prepareManager(at modelDirectory: URL) async throws -> any ParakeetManaging {
        let models: AsrModels
        do {
            models = try AsrModels.loadLocal(from: modelDirectory, version: .v3)
        } catch {
            throw LocalTranscriptionError.parakeetSetupFailed(
                step: .loadingModels,
                modelDirectory: modelDirectory.path,
                reason: error.localizedDescription
            )
        }
        return try await FluidAudioParakeetRuntime.makeManager(models: models, modelDirectory: modelDirectory)
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The system's bsdtar reads xz, so the archive needs nothing bundled to unpack.
    private static func untar(_ archive: URL, into directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xf", archive.path, "-C", directory.path]
        let stderr = Pipe()
        process.standardError = stderr

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        continuation.resume(throwing: BarkCleanModelError.unpackFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

enum BarkCleanModelError: LocalizedError {
    case checksumMismatch(expected: String, actual: String)
    case incompleteArchive
    case unpackFailed(String)
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .checksumMismatch:
            return "The downloaded model didn't match its checksum. Try downloading it again."
        case .incompleteArchive:
            return "The downloaded model is missing files. Try downloading it again."
        case .unpackFailed(let message):
            return "Couldn't unpack the model files\(message.isEmpty ? "" : ": \(message)")."
        case .badResponse(let status):
            return "The model server answered with HTTP \(status). Try again later."
        }
    }
}

/// One file over HTTPS with progress, cancellable from the calling task.
///
/// URLSession's async `download(from:)` reports no progress, so this wraps the delegate API.
/// The finished file is moved out of URLSession's temporary location before the delegate
/// returns, because that location is deleted the moment it does.
final class ModelArchiveDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedByteCount: Int64
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var isCancelled = false

    private init(expectedByteCount: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.expectedByteCount = expectedByteCount
        self.onProgress = onProgress
    }

    static func download(
        from url: URL,
        expectedByteCount: Int64,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let download = ModelArchiveDownload(expectedByteCount: expectedByteCount, onProgress: onProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.start(url, continuation: continuation)
            }
        } onCancel: {
            download.cancel()
        }
    }

    private func start(_ url: URL, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    private func cancel() {
        lock.lock()
        isCancelled = true
        let session = self.session
        lock.unlock()
        session?.invalidateAndCancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        // The session retains its delegate until it is invalidated.
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedByteCount
        onProgress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(BarkCleanModelError.badResponse(http.statusCode)))
            return
        }
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("whale-model-\(UUID().uuidString).download")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A successful task has already finished in didFinishDownloadingTo; this only reports
        // failures, and finish() ignores a second call.
        if let error {
            finish(.failure(error))
        }
    }
}
