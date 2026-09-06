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

    func testCatalogSplitsBundledModelsFromCustomFolder() {
        XCTAssertEqual(
            BuiltInModelCatalog.models(from: .bundled).map(\.id),
            [.parakeetEnglishV2, .whisperLargeV3Turbo]
        )
        XCTAssertEqual(
            BuiltInModelCatalog.models(from: .custom).map(\.id),
            [.whisperLocalFolder]
        )
        XCTAssertEqual(
            BuiltInModelCatalog.allModels.map(\.languageLabel),
            ["English only", "Multilingual", "Auto-detect"]
        )
    }

    func testModelRowModelCoversEveryInstallState() {
        let model = BuiltInModelID.parakeetEnglishV2.descriptor

        let checking = TranscriptionModelRowModel(
            model: model,
            installState: .checking,
            isSelected: false
        )
        XCTAssertTrue(checking.isBusy)
        XCTAssertFalse(checking.status.showsDot)
        XCTAssertFalse(checking.isReady)

        let notInstalled = TranscriptionModelRowModel(
            model: model,
            installState: .notInstalled,
            isSelected: false
        )
        XCTAssertEqual(notInstalled.status, .notInstalled)
        XCTAssertEqual(notInstalled.statusText, "Not Installed")
        XCTAssertEqual(notInstalled.primaryActionTitle, "Download")
        XCTAssertFalse(notInstalled.isBusy)

        let selectedNotInstalled = TranscriptionModelRowModel(
            model: model,
            installState: .notInstalled,
            isSelected: true
        )
        XCTAssertEqual(selectedNotInstalled.status, .active)
        XCTAssertEqual(selectedNotInstalled.primaryActionTitle, "Download")
        XCTAssertFalse(selectedNotInstalled.isReady)

        let downloading = TranscriptionModelRowModel(
            model: model,
            installState: .downloading(progress: 0.42, phase: "Downloading"),
            isSelected: false
        )
        XCTAssertEqual(downloading.progress, 0.42)
        XCTAssertEqual(downloading.statusText, "Downloading · 42%")
        XCTAssertTrue(downloading.isBusy)

        let active = TranscriptionModelRowModel(
            model: model,
            installState: .ready,
            isSelected: true
        )
        XCTAssertTrue(active.isReady)
        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(active.statusText, "Active")
        XCTAssertEqual(active.resetActionTitle, "Delete")

        let inactive = TranscriptionModelRowModel(
            model: model,
            installState: .ready,
            isSelected: false
        )
        XCTAssertEqual(inactive.status, .inactive)
        XCTAssertEqual(inactive.statusText, "Inactive")

        let failed = TranscriptionModelRowModel(
            model: model,
            installState: .failed("Download failed"),
            isSelected: false
        )
        XCTAssertEqual(failed.status, .needsAttention)
        XCTAssertEqual(failed.primaryActionTitle, "Retry")
        XCTAssertEqual(failed.errorText, "Download failed")
    }

    func testMissingWhisperArtifactsRefreshAsNotInstalled() async throws {
        let modelID = BuiltInModelID.whisperLargeV3Turbo
        let folder = try makeTemporaryWhisperModelFolder(function: #function)
        let originalPath = SettingsStore.shared.localModelPath(for: modelID)
        defer {
            SettingsStore.shared.setLocalModelPath(originalPath, for: modelID)
            try? FileManager.default.removeItem(at: folder)
        }

        SettingsStore.shared.setLocalModelPath(folder.path, for: modelID)

        let backend = WhisperTranscriptionBackend()
        let isInstalled = try await backend.isInstalled(modelID: modelID)

        XCTAssertFalse(isInstalled)
    }

    /// A selected model that stops being ready must not hand the selection to another engine;
    /// it remains the active selection while offering a download action.
    func testSelectionSurvivesTheActiveModelBecomingUnavailable() async {
        let originalSelection = SettingsStore.shared.selectedBuiltInModelID
        defer { SettingsStore.shared.selectedBuiltInModelID = originalSelection }

        // Parakeet is installed, Whisper is not — exactly the shape that used to trigger the
        // silent fallback from the selected Whisper model back to Parakeet.
        let service = LocalTranscriptionService(backends: [
            .parakeet: RecordingBackend(),
            .whisper: RecordingBackend(isInstalled: false),
        ])
        let store = TranscriptionModelStore(service: service)

        SettingsStore.shared.selectedBuiltInModelID = .whisperLargeV3Turbo
        await store.refreshNow()

        XCTAssertEqual(SettingsStore.shared.selectedBuiltInModelID, .whisperLargeV3Turbo)
        XCTAssertEqual(store.installState(for: .whisperLargeV3Turbo), .notInstalled)

        let row = TranscriptionModelRowModel(
            model: BuiltInModelID.whisperLargeV3Turbo.descriptor,
            installState: store.installState(for: .whisperLargeV3Turbo),
            isSelected: true
        )
        XCTAssertEqual(row.status, .active)
        XCTAssertEqual(row.primaryActionTitle, "Download")
        XCTAssertFalse(row.isReady)
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

        XCTAssertEqual(descriptor.title, "Whisper Large v3 Turbo")
        // The markdown label is the wording baked into every exported transcript, so it is
        // deliberately not renamed alongside the settings-row title.
        XCTAssertEqual(descriptor.markdownLabel, "Whisper Large V3 Turbo")
        XCTAssertTrue(descriptor.installationPrompt.contains(descriptor.title))
        XCTAssertTrue(markdown.contains("**Model:** Whisper Large V3 Turbo"))
        XCTAssertFalse(markdown.contains("Cleanup"))
        XCTAssertTrue(markdown.contains("## Transcript\n\nHello world"))
    }

    func testWhisperBuiltInDetectsLanguageFromSpeech() {
        let options = WhisperBuiltInConfiguration.decodingOptions()

        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
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
            descriptor: BuiltInModelID.whisperLocalFolder.descriptor
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
            environment: [:],
            bundleIdentifier: "com.sumitrk.transcribe-meeting"
        )

        XCTAssertFalse(runtimeInfo.isSandboxed)
        XCTAssertEqual(runtimeInfo.whaleSupportDirectoryURL.path, "/Users/tester/Library/Application Support/Whale")
        XCTAssertEqual(runtimeInfo.recordingsDirectoryURL.path, "/Users/tester/Library/Application Support/Whale/Recordings")
        XCTAssertEqual(runtimeInfo.transcriptsDirectoryURL.path, "/Users/tester/Library/Application Support/Whale/Transcripts")
        XCTAssertEqual(
            runtimeInfo.parakeetEnglishV2DirectoryURL.path,
            "/Users/tester/Library/Application Support/Whale/Models/parakeet-tdt-0.6b-v2"
        )
    }

    func testAppRuntimeInfoSeparatesDevelopmentApplicationSupportPath() {
        XCTAssertEqual(
            AppRuntimeInfo.historyDirectoryName(for: "com.sumitrk.transcribe-meeting"),
            "Whale"
        )
        XCTAssertEqual(
            AppRuntimeInfo.historyDirectoryName(for: "com.sumitrk.transcribe-meeting.dev"),
            "Whale-Dev"
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
            environment: ["APP_SANDBOX_CONTAINER_ID": "com.sumitrk.transcribe-meeting"],
            bundleIdentifier: "com.sumitrk.transcribe-meeting"
        )

        XCTAssertTrue(runtimeInfo.isSandboxed)
        XCTAssertEqual(
            runtimeInfo.transcriptsDirectoryURL.path,
            "/Users/tester/Library/Containers/com.sumitrk.transcribe-meeting/Data/Library/Application Support/Whale/Transcripts"
        )
        XCTAssertEqual(
            runtimeInfo.parakeetEnglishV2DirectoryURL.path,
            "/Users/tester/Library/Containers/com.sumitrk.transcribe-meeting/Data/Library/Application Support/Whale/Models/parakeet-tdt-0.6b-v2"
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

    /// Upgrading past FluidAudio 0.15 must adopt the ~440 MB already on disk rather than
    /// declaring the model missing and downloading it again beside the orphaned copy.
    func testParakeetAdoptsPre015InstallInsteadOfRedownloading() async throws {
        let fm = FileManager.default
        let runtimeInfo = makeParakeetRuntimeInfo(function: #function)
        let legacy = runtimeInfo.legacyParakeetEnglishV2DirectoryURL
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        let payload = legacy.appendingPathComponent("Encoder.mlmodelc")
        try "weights".write(to: payload, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: runtimeInfo.homeDirectoryURL) }

        let backend = ParakeetTranscriptionBackend(
            runtime: FakeParakeetRuntime(),
            runtimeInfoProvider: { runtimeInfo }
        )
        _ = try await backend.isInstalled(modelID: .parakeetEnglishV2)

        let adopted = runtimeInfo.parakeetEnglishV2DirectoryURL
        XCTAssertFalse(fm.fileExists(atPath: legacy.path), "legacy directory should be moved, not left behind")
        XCTAssertTrue(fm.fileExists(atPath: adopted.path), "model should now sit at the name FluidAudio derives")
        XCTAssertEqual(
            try String(contentsOf: adopted.appendingPathComponent("Encoder.mlmodelc"), encoding: .utf8),
            "weights",
            "the existing model files should be carried over, not recreated"
        )
    }

    /// A fresh install must not be clobbered by a stale legacy directory left over from
    /// a partially-completed upgrade.
    func testParakeetKeepsCurrentInstallWhenALegacyDirectoryAlsoExists() async throws {
        let fm = FileManager.default
        let runtimeInfo = makeParakeetRuntimeInfo(function: #function)
        let legacy = runtimeInfo.legacyParakeetEnglishV2DirectoryURL
        let current = runtimeInfo.parakeetEnglishV2DirectoryURL
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try "stale".write(to: legacy.appendingPathComponent("Encoder.mlmodelc"), atomically: true, encoding: .utf8)
        try "current".write(to: current.appendingPathComponent("Encoder.mlmodelc"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: runtimeInfo.homeDirectoryURL) }

        let backend = ParakeetTranscriptionBackend(
            runtime: FakeParakeetRuntime(),
            runtimeInfoProvider: { runtimeInfo }
        )
        _ = try await backend.isInstalled(modelID: .parakeetEnglishV2)

        XCTAssertEqual(
            try String(contentsOf: current.appendingPathComponent("Encoder.mlmodelc"), encoding: .utf8),
            "current",
            "an existing install must win over a leftover legacy directory"
        )
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
            environment: [:],
            bundleIdentifier: nil
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

    private let isInstalledResult: Bool

    init(isInstalled: Bool = true) {
        self.isInstalledResult = isInstalled
    }

    func isInstalled(modelID: BuiltInModelID) async throws -> Bool {
        checked.append(modelID)
        return isInstalledResult
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

    func transcribeDiskBacked(_: URL, source _: AudioSource) async throws -> String {
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
        progressHandler _: ProgressHandler?
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

/// The Parakeet cache directory name is a contract with FluidAudio: `AsrModels` resolves
/// every path as `<parent of what we pass>/<Repo.folderName>`, so if these two drift apart
/// Whale checks, resets, and reports on a directory the model does not live in. FluidAudio
/// 0.15 silently changed this name by stripping `-coreml`, which made every existing install
/// look missing. Pin it so the next change fails here instead of in the field.
final class ParakeetModelDirectoryContractTests: XCTestCase {
    func testDirectoryNameMatchesFluidAudioFolderName() {
        XCTAssertEqual(
            AppRuntimeInfo.parakeetEnglishV2DirectoryName,
            Repo.parakeetV2.folderName
        )
    }

    func testLegacyDirectoryNameIsTheOneEarlierBuildsUsed() {
        XCTAssertEqual(
            AppRuntimeInfo.legacyParakeetEnglishV2DirectoryName,
            "parakeet-tdt-0.6b-v2-coreml"
        )
        XCTAssertNotEqual(
            AppRuntimeInfo.legacyParakeetEnglishV2DirectoryName,
            AppRuntimeInfo.parakeetEnglishV2DirectoryName
        )
    }
}
