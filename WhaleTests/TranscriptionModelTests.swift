import XCTest
import FluidAudio
@testable import Whale

@MainActor
final class TranscriptionModelTests: XCTestCase {
    func testSelectedModelDefaultsToParakeet() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.selectedBuiltInModelID, .parakeetEnglishV2)
    }

    func testShortcutLabelsCoverModifierOnlyAndRegularKeys() {
        let store = SettingsStore(userDefaults: UserDefaults(suiteName: #function)!)
        let commandShift = Int(NSEvent.ModifierFlags([.command, .shift]).rawValue)

        XCTAssertEqual(store.keyLabel(keyCode: 63, modifiers: 0), "Globe / Fn")
        XCTAssertEqual(store.keyLabel(keyCode: 54, modifiers: 0), "Right ⌘")
        XCTAssertEqual(store.keyLabel(keyCode: 53, modifiers: 0), "⎋")
        XCTAssertEqual(store.keyLabel(keyCode: 123, modifiers: 0), "←")
        XCTAssertEqual(store.keyLabel(keyCode: 0, modifiers: 0), "A")
        XCTAssertEqual(store.keyLabel(keyCode: 17, modifiers: commandShift), "⇧⌘T")
    }

    func testMissingSelectedModelKeyMigratesToParakeet() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("unknown-model", forKey: "selectedBuiltInModelID")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.selectedBuiltInModelID, .parakeetEnglishV2)
    }

    func testTranscriptFolderSelectionPersistsAsResolvedURL() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SettingsStore(userDefaults: defaults)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Whale-\(#function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        store.setTranscriptFolderURL(folder)

        XCTAssertEqual(store.transcriptFolder.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(URL(fileURLWithPath: store.transcriptFolderPath).standardizedFileURL.path, folder.standardizedFileURL.path)
    }

    func testLocalModelFolderSelectionPersistsAsResolvedURL() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SettingsStore(userDefaults: defaults)
        let folder = try makeTemporaryWhisperModelFolder(function: #function)

        store.setLocalModelURL(folder, for: .whisperLocalFolder)

        XCTAssertEqual(store.localModelURL(for: .whisperLocalFolder)?.standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertEqual(
            store.localModelPath(for: .whisperLocalFolder).map { URL(fileURLWithPath: $0).standardizedFileURL.path },
            folder.standardizedFileURL.path
        )
    }

    func testCatalogGroupsContainExpectedBuiltInModels() {
        XCTAssertEqual(BuiltInModelGroup.allCases, [.parakeet, .whisper])
        XCTAssertEqual(BuiltInModelCatalog.models(in: .parakeet).map(\.id), [.parakeetEnglishV2])
        XCTAssertEqual(
            BuiltInModelCatalog.models(in: .whisper).map(\.id),
            [.whisperLargeV3Turbo, .whisperLocalFolder]
        )
    }

    func testModelRowModelCoversEveryInstallState() {
        let model = BuiltInModelID.parakeetEnglishV2.descriptor

        let checking = TranscriptionModelRowModel(
            model: model,
            installState: .checking,
            isSelected: false
        )
        XCTAssertTrue(checking.showsProgress)
        XCTAssertFalse(checking.isReady)

        let notInstalled = TranscriptionModelRowModel(
            model: model,
            installState: .notInstalled,
            isSelected: false
        )
        XCTAssertEqual(notInstalled.primaryActionTitle, "Install")
        XCTAssertFalse(notInstalled.showsProgress)

        let downloading = TranscriptionModelRowModel(
            model: model,
            installState: .downloading(progress: 0.42, phase: "Downloading"),
            isSelected: false
        )
        XCTAssertEqual(downloading.progress, 0.42)
        XCTAssertEqual(downloading.statusText, "Downloading")

        let ready = TranscriptionModelRowModel(
            model: model,
            installState: .ready,
            isSelected: true
        )
        XCTAssertTrue(ready.isReady)
        XCTAssertTrue(ready.statusText.contains("Active and ready"))
        XCTAssertEqual(ready.resetActionTitle, "Reset Cache")

        let failed = TranscriptionModelRowModel(
            model: model,
            installState: .failed("Download failed"),
            isSelected: false
        )
        XCTAssertEqual(failed.primaryActionTitle, "Retry")
        XCTAssertEqual(failed.errorText, "Download failed")
    }

    func testCoordinatorRoutesByModelGroup() async throws {
        let parakeet = RecordingBackend()
        let whisper = RecordingBackend()
        let service = LocalTranscriptionService(backends: [
            .parakeet: parakeet,
            .whisper: whisper,
        ])

        _ = try await service.isModelInstalled(.parakeetEnglishV2)
        try await service.installModel(.whisperLargeV3Turbo)
        try await service.connectLocalModel(
            .whisperLocalFolder,
            folderURL: URL(fileURLWithPath: "/tmp/local-whisper-model", isDirectory: true)
        )
        _ = try await service.transcribe(
            modelID: .parakeetEnglishV2,
            wavURL: URL(fileURLWithPath: "/tmp/test.wav"),
            source: .microphone
        )

        let parakeetCalls = await parakeet.snapshot()
        let whisperCalls = await whisper.snapshot()

        XCTAssertEqual(parakeetCalls.checked, [.parakeetEnglishV2])
        XCTAssertEqual(parakeetCalls.transcribed, [.parakeetEnglishV2])
        XCTAssertEqual(whisperCalls.installed, [.whisperLargeV3Turbo])
        XCTAssertEqual(whisperCalls.connected, [.whisperLocalFolder])
    }

    func testSelectedModelTextComesFromDescriptor() throws {
        let descriptor = BuiltInModelID.whisperLargeV3Turbo.descriptor

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Whale-\(#function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = try TranscriptArtifactWriter().write(
            .init(
                startedAt: Date(timeIntervalSince1970: 0),
                durationMinutes: 3,
                model: descriptor,
                transcript: "Hello world"
            ),
            to: folder
        )
        let markdown = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(descriptor.markdownLabel, "Whisper Large V3 Turbo")
        XCTAssertTrue(descriptor.installationPrompt.contains("Whisper Large V3 Turbo"))
        XCTAssertTrue(markdown.contains("**Model:** Whisper Large V3 Turbo"))
        XCTAssertFalse(markdown.contains("Cleanup"))
        XCTAssertTrue(markdown.contains("## Transcript\n\nHello world"))
    }

    func testWhisperBuiltInDefaultsToEnglish() {
        let options = WhisperBuiltInConfiguration.decodingOptions()

        XCTAssertEqual(options.language, "en")
        XCTAssertFalse(options.detectLanguage)
        XCTAssertEqual(options.task, .transcribe)
    }

    func testRefreshKeepsSelectedWhisperModelWhileChecking() async {
        let originalSelection = SettingsStore.shared.selectedBuiltInModelID
        defer {
            SettingsStore.shared.selectedBuiltInModelID = originalSelection
        }

        let parakeet = RecordingBackend()
        let whisper = RecordingBackend()
        let service = LocalTranscriptionService(backends: [
            .parakeet: parakeet,
            .whisper: whisper,
        ])
        let store = TranscriptionModelStore(service: service)

        await store.refresh(.parakeetEnglishV2)
        await store.refresh(.whisperLargeV3Turbo)

        SettingsStore.shared.selectedBuiltInModelID = .whisperLargeV3Turbo

        await store.refresh(.whisperLargeV3Turbo)

        XCTAssertEqual(SettingsStore.shared.selectedBuiltInModelID, .whisperLargeV3Turbo)
    }

    func testModelStoreSharesOperationLifecycleAcrossInstallResetAndConnect() async {
        let backend = ModelOperationBackend()
        let service = LocalTranscriptionService(backends: [.parakeet: backend, .whisper: backend])
        let store = TranscriptionModelStore(service: service)

        store.install(.parakeetEnglishV2)
        await backend.waitUntilStarted(.install)
        XCTAssertEqual(
            store.installState(for: .parakeetEnglishV2),
            .downloading(progress: 0.25, phase: "Downloading")
        )
        await backend.release(.install)
        await waitForState(store, .parakeetEnglishV2, equals: .ready)

        store.reset(.parakeetEnglishV2)
        await backend.waitUntilStarted(.reset)
        XCTAssertEqual(store.installState(for: .parakeetEnglishV2), .checking)
        await backend.release(.reset)
        await waitForState(store, .parakeetEnglishV2, equals: .notInstalled)

        store.connectLocalModel(
            .whisperLocalFolder,
            folderURL: URL(fileURLWithPath: "/tmp/local-whisper-model", isDirectory: true)
        )
        await backend.waitUntilStarted(.connect)
        XCTAssertEqual(
            store.installState(for: .whisperLocalFolder),
            .downloading(progress: 0.25, phase: "Downloading")
        )
        await backend.release(.connect)
        await waitForState(store, .whisperLocalFolder, equals: .ready)
    }

    func testModelStoreCancellationIgnoresLateProgressAndCompletion() async {
        let backend = ModelOperationBackend()
        let service = LocalTranscriptionService(backends: [.parakeet: backend, .whisper: backend])
        let store = TranscriptionModelStore(service: service)

        store.install(.parakeetEnglishV2)
        await backend.waitUntilStarted(.install)
        store.cancel(.parakeetEnglishV2)
        XCTAssertEqual(store.installState(for: .parakeetEnglishV2), .notInstalled)

        await backend.emitProgress(.install)
        await backend.release(.install)
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(store.installState(for: .parakeetEnglishV2), .notInstalled)
    }

    private func waitForState(
        _ store: TranscriptionModelStore,
        _ modelID: BuiltInModelID,
        equals expected: NativeModelInstallState
    ) async {
        for _ in 0..<100 {
            if store.installState(for: modelID) == expected {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for \(modelID) to reach \(expected)")
    }

    func testLocalWhisperPromptMentionsChoosingFolder() {
        let descriptor = BuiltInModelID.whisperLocalFolder.descriptor

        XCTAssertEqual(descriptor.provisioning, .localFolder)
        XCTAssertTrue(descriptor.installationPrompt.contains("choose a WhisperKit/Core ML folder"))
    }

    func testWhisperLocalFolderValidationSucceedsWhenArtifactsExist() throws {
        let folder = try makeTemporaryWhisperModelFolder(function: #function)
        try makeWhisperArtifacts(in: folder, includeTokenizer: true)

        let validation = try WhisperTranscriptionBackend.validateModelFolder(
            at: folder,
            descriptor: .init(
                id: .whisperLocalFolder,
                group: .whisper,
                provisioning: .localFolder,
                title: "Local Whisper Folder",
                detail: "",
                markdownLabel: ""
            )
        )

        XCTAssertEqual(validation.modelFolder.path, folder.path)
        XCTAssertEqual(validation.tokenizerFolder?.path, folder.path)
        XCTAssertEqual(validation.inferredModelName, folder.lastPathComponent)
    }

    func testWhisperLocalFolderValidationSucceedsWithoutTokenizer() throws {
        let folder = try makeTemporaryWhisperModelFolder(function: #function)
        try makeWhisperArtifacts(in: folder, includeTokenizer: false)

        let validation = try WhisperTranscriptionBackend.validateModelFolder(
            at: folder,
            descriptor: BuiltInModelID.whisperLocalFolder.descriptor
        )

        XCTAssertNil(validation.tokenizerFolder)
        XCTAssertEqual(validation.inferredModelName, folder.lastPathComponent)
    }

    func testWhisperLocalFolderValidationReportsMissingArtifacts() throws {
        let folder = try makeTemporaryWhisperModelFolder(function: #function)

        XCTAssertThrowsError(
            try WhisperTranscriptionBackend.validateModelFolder(
                at: folder,
                descriptor: BuiltInModelID.whisperLocalFolder.descriptor
            )
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Local Whisper Folder could not be loaded."))
            XCTAssertTrue(message.contains("Folder:"))
            XCTAssertTrue(message.contains("Problems:"))
            XCTAssertTrue(message.contains("Missing MelSpectrogram.mlmodelc or MelSpectrogram.mlpackage."))
            XCTAssertTrue(message.contains("Missing AudioEncoder.mlmodelc or AudioEncoder.mlpackage."))
            XCTAssertTrue(message.contains("Missing TextDecoder.mlmodelc or TextDecoder.mlpackage."))
            XCTAssertTrue(message.contains("Choose a WhisperKit/Core ML folder"))
        }
    }

    func testAppRuntimeInfoUsesUnsandboxedApplicationSupportPath() {
        let runtimeInfo = AppRuntimeInfo(
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            appSupportDirectoryURL: URL(fileURLWithPath: "/Users/tester/Library/Application Support", isDirectory: true),
            environment: [:]
        )

        XCTAssertFalse(runtimeInfo.isSandboxed)
        XCTAssertEqual(runtimeInfo.whaleSupportDirectoryURL.path, "/Users/tester/Library/Application Support/Whale")
        XCTAssertEqual(runtimeInfo.recordingsDirectoryURL.path, "/Users/tester/Library/Application Support/Whale/Recordings")
        XCTAssertEqual(runtimeInfo.transcriptsDirectoryURL.path, "/Users/tester/Library/Application Support/Whale/Transcripts")
        XCTAssertEqual(
            runtimeInfo.parakeetEnglishV2DirectoryURL.path,
            "/Users/tester/Library/Application Support/Whale/Models/parakeet-tdt-0.6b-v2-coreml"
        )
    }

    func testAppRuntimeInfoUsesSandboxContainerPath() {
        let runtimeInfo = AppRuntimeInfo(
            homeDirectoryURL: URL(
                fileURLWithPath: "/Users/tester/Library/Containers/com.sumitrk.transcribe-meeting/Data",
                isDirectory: true
            ),
            appSupportDirectoryURL: URL(
                fileURLWithPath: "/Users/tester/Library/Containers/com.sumitrk.transcribe-meeting/Data/Library/Application Support",
                isDirectory: true
            ),
            environment: ["APP_SANDBOX_CONTAINER_ID": "com.sumitrk.transcribe-meeting"]
        )

        XCTAssertTrue(runtimeInfo.isSandboxed)
        XCTAssertEqual(
            runtimeInfo.transcriptsDirectoryURL.path,
            "/Users/tester/Library/Containers/com.sumitrk.transcribe-meeting/Data/Library/Application Support/Whale/Transcripts"
        )
        XCTAssertEqual(
            runtimeInfo.parakeetEnglishV2DirectoryURL.path,
            "/Users/tester/Library/Containers/com.sumitrk.transcribe-meeting/Data/Library/Application Support/Whale/Models/parakeet-tdt-0.6b-v2-coreml"
        )
        XCTAssertTrue(runtimeInfo.storageDescription.contains("sandboxed"))
    }

    func testParakeetInstallUsesExplicitAppOwnedPath() async throws {
        let runtime = FakeParakeetRuntime()
        let runtimeInfo = makeParakeetRuntimeInfo(function: #function)
        let backend = ParakeetTranscriptionBackend(
            runtime: runtime,
            runtimeInfoProvider: { runtimeInfo }
        )

        try await backend.install(modelID: .parakeetEnglishV2, progressHandler: nil)

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.downloadedPaths, [runtimeInfo.parakeetEnglishV2DirectoryURL.path])
        XCTAssertEqual(snapshot.validatedPaths, [runtimeInfo.parakeetEnglishV2DirectoryURL.path])
        XCTAssertEqual(snapshot.preparedPaths, [runtimeInfo.parakeetEnglishV2DirectoryURL.path])
        XCTAssertTrue(snapshot.existingPaths.contains(runtimeInfo.parakeetEnglishV2DirectoryURL.path))
    }

    func testParakeetInstallReportsDownloadFailuresSeparately() async {
        let runtime = FakeParakeetRuntime()
        await runtime.setDownloadError(FakeParakeetRuntimeError.downloadFailed)
        let runtimeInfo = makeParakeetRuntimeInfo(function: #function)
        let backend = ParakeetTranscriptionBackend(
            runtime: runtime,
            runtimeInfoProvider: { runtimeInfo }
        )

        do {
            try await backend.install(modelID: .parakeetEnglishV2, progressHandler: nil)
            XCTFail("Expected download failure")
        } catch let error as LocalTranscriptionError {
            guard case .parakeetSetupFailed(let step, let modelDirectory, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(step, .downloading)
            XCTAssertEqual(modelDirectory, runtimeInfo.parakeetEnglishV2DirectoryURL.path)
            XCTAssertTrue(reason.contains("download"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testParakeetInstallReportsValidationFailuresAfterDownload() async {
        let runtime = FakeParakeetRuntime()
        await runtime.setValidateError(FakeParakeetRuntimeError.validationFailed)
        let runtimeInfo = makeParakeetRuntimeInfo(function: #function)
        let backend = ParakeetTranscriptionBackend(
            runtime: runtime,
            runtimeInfoProvider: { runtimeInfo }
        )

        do {
            try await backend.install(modelID: .parakeetEnglishV2, progressHandler: nil)
            XCTFail("Expected validation failure")
        } catch let error as LocalTranscriptionError {
            guard case .parakeetSetupFailed(let step, let modelDirectory, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(step, .validatingFiles)
            XCTAssertEqual(modelDirectory, runtimeInfo.parakeetEnglishV2DirectoryURL.path)
            XCTAssertTrue(reason.contains("validation"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testParakeetInstallReportsInitializationFailuresAfterValidation() async {
        let runtime = FakeParakeetRuntime()
        await runtime.setPrepareError(FakeParakeetRuntimeError.prepareFailed)
        let runtimeInfo = makeParakeetRuntimeInfo(function: #function)
        let backend = ParakeetTranscriptionBackend(
            runtime: runtime,
            runtimeInfoProvider: { runtimeInfo }
        )

        do {
            try await backend.install(modelID: .parakeetEnglishV2, progressHandler: nil)
            XCTFail("Expected initialization failure")
        } catch let error as LocalTranscriptionError {
            guard case .parakeetSetupFailed(let step, let modelDirectory, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(step, .preparingRuntime)
            XCTAssertEqual(modelDirectory, runtimeInfo.parakeetEnglishV2DirectoryURL.path)
            XCTAssertTrue(reason.contains("initialization"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testParakeetEnsureReadySucceedsAfterSuccessfulPrewarm() async throws {
        let runtime = FakeParakeetRuntime()
        let runtimeInfo = makeParakeetRuntimeInfo(function: #function)
        let backend = ParakeetTranscriptionBackend(
            runtime: runtime,
            runtimeInfoProvider: { runtimeInfo }
        )

        try await backend.install(modelID: .parakeetEnglishV2, progressHandler: nil)
        let transcript = try await backend.transcribe(
            modelID: .parakeetEnglishV2,
            wavURL: URL(fileURLWithPath: "/tmp/test.wav"),
            source: .microphone
        )

        let snapshot = await runtime.snapshot()
        XCTAssertEqual(transcript, "ok")
        XCTAssertEqual(snapshot.preparedPaths, [runtimeInfo.parakeetEnglishV2DirectoryURL.path])
    }

    private func makeTemporaryWhisperModelFolder(function: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Whale-\(function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeParakeetRuntimeInfo(function: String) -> AppRuntimeInfo {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Whale-\(function)-\(UUID().uuidString)", isDirectory: true)

        return AppRuntimeInfo(
            homeDirectoryURL: root,
            appSupportDirectoryURL: root.appendingPathComponent("Library/Application Support", isDirectory: true),
            environment: [:]
        )
    }

    private func makeWhisperArtifacts(in folder: URL, includeTokenizer: Bool) throws {
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let path = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }

        if includeTokenizer {
            let tokenizer = folder.appendingPathComponent("tokenizer.json")
            try Data("{}".utf8).write(to: tokenizer)
        }
    }
}

actor ModelOperationBackend: BuiltInTranscriptionBackend {
    enum Operation: Hashable {
        case install
        case reset
        case connect
    }

    private var started: Set<Operation> = []
    private var released: Set<Operation> = []
    private var progressHandlers: [Operation: ModelInstallProgressHandler] = [:]

    func waitUntilStarted(_ operation: Operation) async {
        while !started.contains(operation) {
            await Task.yield()
        }
    }

    func release(_ operation: Operation) {
        released.insert(operation)
    }

    func emitProgress(_ operation: Operation) {
        progressHandlers[operation]?(ModelInstallProgress(fractionCompleted: 0.75, phase: "Late progress"))
    }

    func isInstalled(modelID _: BuiltInModelID) async throws -> Bool {
        true
    }

    func prepare(modelID _: BuiltInModelID) async throws { }

    func install(
        modelID _: BuiltInModelID,
        progressHandler: ModelInstallProgressHandler?
    ) async throws {
        try await waitForRelease(
            .install,
            progressHandler: progressHandler
        )
    }

    func connectLocalModel(
        modelID _: BuiltInModelID,
        folderURL _: URL,
        progressHandler: ModelInstallProgressHandler?
    ) async throws {
        try await waitForRelease(
            .connect,
            progressHandler: progressHandler
        )
    }

    func transcribe(
        modelID _: BuiltInModelID,
        wavURL _: URL,
        source _: AudioSource
    ) async throws -> String {
        "ok"
    }

    func resetModel(modelID _: BuiltInModelID) async throws {
        try await waitForRelease(.reset, progressHandler: nil)
    }

    private func waitForRelease(
        _ operation: Operation,
        progressHandler: ModelInstallProgressHandler?
    ) async throws {
        started.insert(operation)
        if let progressHandler {
            progressHandlers[operation] = progressHandler
            progressHandler(ModelInstallProgress(fractionCompleted: 0.25, phase: "Downloading"))
        }

        while !released.contains(operation) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

actor RecordingBackend: BuiltInTranscriptionBackend {
    private(set) var checked: [BuiltInModelID] = []
    private(set) var installed: [BuiltInModelID] = []
    private(set) var connected: [BuiltInModelID] = []
    private(set) var transcribed: [BuiltInModelID] = []

    func isInstalled(modelID: BuiltInModelID) async throws -> Bool {
        checked.append(modelID)
        return true
    }

    func install(
        modelID: BuiltInModelID,
        progressHandler _: ModelInstallProgressHandler?
    ) async throws {
        installed.append(modelID)
    }

    func connectLocalModel(
        modelID: BuiltInModelID,
        folderURL _: URL,
        progressHandler _: ModelInstallProgressHandler?
    ) async throws {
        connected.append(modelID)
    }

    func transcribe(
        modelID: BuiltInModelID,
        wavURL _: URL,
        source _: AudioSource
    ) async throws -> String {
        transcribed.append(modelID)
        return "ok"
    }

    func snapshot() -> (
        checked: [BuiltInModelID],
        installed: [BuiltInModelID],
        connected: [BuiltInModelID],
        transcribed: [BuiltInModelID]
    ) {
        (checked, installed, connected, transcribed)
    }
}

enum FakeParakeetRuntimeError: LocalizedError {
    case downloadFailed
    case validationFailed
    case prepareFailed

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "download failure"
        case .validationFailed:
            return "validation failure"
        case .prepareFailed:
            return "initialization failure"
        }
    }
}

final class FakeParakeetManager: @unchecked Sendable, ParakeetManaging {
    func transcribe(_: URL, source _: AudioSource) async throws -> String {
        "ok"
    }

    func transcribeStreaming(_: URL, source _: AudioSource) async throws -> String {
        "ok"
    }
}

actor FakeParakeetRuntime: ParakeetModelRuntime {
    private var existingPaths: Set<String> = []
    private var downloadError: Error?
    private var validateError: Error?
    private var prepareError: Error?
    private var checkedPaths: [String] = []
    private var downloadedPaths: [String] = []
    private var validatedPaths: [String] = []
    private var preparedPaths: [String] = []

    func setDownloadError(_ error: Error?) {
        downloadError = error
    }

    func setValidateError(_ error: Error?) {
        validateError = error
    }

    func setPrepareError(_ error: Error?) {
        prepareError = error
    }

    func modelsExist(at modelDirectory: URL) async -> Bool {
        checkedPaths.append(modelDirectory.path)
        return existingPaths.contains(modelDirectory.path)
    }

    func downloadModels(
        to modelDirectory: URL,
        progressHandler _: DownloadUtils.ProgressHandler?
    ) async throws {
        downloadedPaths.append(modelDirectory.path)

        if let downloadError {
            throw downloadError
        }

        existingPaths.insert(modelDirectory.path)
    }

    func validateModels(at modelDirectory: URL) async throws {
        validatedPaths.append(modelDirectory.path)

        if let validateError {
            throw validateError
        }
    }

    func prepareManager(at modelDirectory: URL) async throws -> any ParakeetManaging {
        preparedPaths.append(modelDirectory.path)

        if let prepareError {
            throw prepareError
        }

        return FakeParakeetManager()
    }

    func snapshot() -> (
        existingPaths: Set<String>,
        checkedPaths: [String],
        downloadedPaths: [String],
        validatedPaths: [String],
        preparedPaths: [String]
    ) {
        (existingPaths, checkedPaths, downloadedPaths, validatedPaths, preparedPaths)
    }
}
