import Combine
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
            BuiltInModelCatalog.allModels.map(\.capabilityLabel),
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
        let options = WhisperBuiltInConfiguration.decodingOptions(language: nil)

        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
        XCTAssertEqual(options.task, .transcribe)
    }

    /// Naming a language has to switch detection off, not merely supply a hint: leaving
    /// `detectLanguage` on would let the decoder overrule the user's explicit choice.
    func testWhisperBuiltInPinsTheChosenLanguageAndStopsDetecting() {
        let options = WhisperBuiltInConfiguration.decodingOptions(language: "es")

        XCTAssertEqual(options.language, "es")
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

@MainActor
final class ModelInstallFeedbackTests: XCTestCase {

    /// The percent belongs to the transfer. Carrying it into the phases that follow renders
    /// "· 100%" beside a spinner, which is what made a working three-minute Core ML compile
    /// look like a wedged download.
    func testWorkPhasesAfterTheTransferCarryNoPercent() {
        let model = BuiltInModelID.whisperLargeV3Turbo.descriptor

        let loading = TranscriptionModelRowModel(
            model: model,
            installState: .downloading(progress: nil, phase: WhisperBuiltInConfiguration.loadingPhase),
            isSelected: false
        )

        XCTAssertEqual(loading.statusText, WhisperBuiltInConfiguration.loadingPhase)
        XCTAssertFalse(loading.statusText.contains("%"))
        XCTAssertNil(loading.progress)
        XCTAssertTrue(loading.isBusy)
    }

    /// A real transfer still reports where it has got to.
    func testTransferPhaseStillShowsItsPercent() {
        let downloading = TranscriptionModelRowModel(
            model: BuiltInModelID.whisperLargeV3Turbo.descriptor,
            installState: .downloading(progress: 0.42, phase: "Downloading"),
            isSelected: false
        )

        XCTAssertEqual(downloading.statusText, "Downloading · 42%")
    }

    /// The app sits at 0% CPU while Core ML compiles out of process, so the row is the only
    /// place the user can learn the wait is expected rather than a hang.
    func testLoadingPhaseNamesTheWait() {
        let phase = WhisperBuiltInConfiguration.loadingPhase

        XCTAssertTrue(
            phase.lowercased().contains("minute"),
            "the load phase has to say how long it can take, or it reads as stuck"
        )
        XCTAssertFalse(phase.contains("%"))
    }

    /// Deleting is only offered for checkpoints the app downloaded. The custom row points at
    /// a folder the user converted themselves, and erasing that would be indefensible.
    func testOnlyAppDownloadedModelsOfferDeletion() {
        XCTAssertEqual(BuiltInModelID.parakeetEnglishV2.descriptor.resetActionTitle, "Delete")
        XCTAssertEqual(BuiltInModelID.whisperLargeV3Turbo.descriptor.resetActionTitle, "Delete")
        XCTAssertEqual(BuiltInModelID.whisperLocalFolder.descriptor.resetActionTitle, "Disconnect")
    }

    /// The safety property, stated directly: nothing the user supplied may be deleted, and it
    /// is decided by how a model is provisioned so a model added later cannot get it wrong.
    func testTheAppNeverClaimsOwnershipOfFilesTheUserSupplied() {
        for model in BuiltInModelCatalog.allModels {
            switch model.provisioning {
            case .download:
                XCTAssertTrue(model.ownsModelFiles, "\(model.id) downloads its own files")
                XCTAssertEqual(model.resetActionTitle, "Delete")
            case .localFolder:
                XCTAssertFalse(
                    model.ownsModelFiles,
                    "\(model.id) points at the user's folder and must never delete it"
                )
                XCTAssertEqual(model.resetActionTitle, "Disconnect")
            }
        }
    }

    /// The reset action only reaches the row once the model is installed, which is what makes
    /// "Delete" safe to show unconditionally in the menu.
    func testResetIsOfferedOnlyOnceInstalled() {
        let model = BuiltInModelID.whisperLargeV3Turbo.descriptor

        let ready = TranscriptionModelRowModel(model: model, installState: .ready, isSelected: false)
        XCTAssertEqual(ready.resetActionTitle, "Delete")

        let notInstalled = TranscriptionModelRowModel(model: model, installState: .notInstalled, isSelected: false)
        XCTAssertNil(notInstalled.resetActionTitle)

        let downloading = TranscriptionModelRowModel(
            model: model,
            installState: .downloading(progress: nil, phase: "x"),
            isSelected: false
        )
        XCTAssertNil(downloading.resetActionTitle)
    }
}

@MainActor
final class TranscriptionLanguageTests: XCTestCase {

    // MARK: - Catalog

    /// Whisper publishes 112 name→code pairs for 100 codes — `castilian` and `spanish` are
    /// both `es`. Iterating the raw dictionary would put Spanish in the menu twice.
    func testCatalogDeduplicatesAliasedLanguageCodes() {
        XCTAssertEqual(TranscriptionLanguageCatalog.supportedCodes.count, 100)
        XCTAssertEqual(TranscriptionLanguageCatalog.allOptions.count, 100)

        let ids = TranscriptionLanguageCatalog.allOptions.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "a language code reached the menu twice")

        XCTAssertEqual(ids.filter { $0 == "es" }.count, 1)
        XCTAssertEqual(ids.filter { $0 == "zh" }.count, 1)
    }

    func testEveryLanguageHasAReadableName() {
        for option in TranscriptionLanguageCatalog.allOptions {
            XCTAssertFalse(option.title.isEmpty, "\(option.id) has no display name")
            XCTAssertNotEqual(
                option.title,
                option.id,
                "\(option.id) fell back to its raw code instead of a name"
            )
        }

        XCTAssertEqual(TranscriptionLanguageOption.language(code: "en").title, "English")
        XCTAssertEqual(TranscriptionLanguageOption.autoDetect.title, "Auto-detect")
    }

    func testLanguagesAreSortedByTheNameShownRatherThanByCode() {
        let titles = TranscriptionLanguageCatalog.allOptions.map(\.title)
        let sorted = titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        XCTAssertEqual(titles, sorted)
    }

    func testAutoDetectAsksTheDecoderToDetectAndALanguageDoesNot() {
        XCTAssertNil(TranscriptionLanguageOption.autoDetect.decodingLanguageCode)
        XCTAssertEqual(TranscriptionLanguageOption.language(code: "de").decodingLanguageCode, "de")
    }

    // MARK: - Capability

    /// Not knowing is the absence of a record, so it round-trips as a missing key rather than
    /// as a stored value meaning "no".
    func testCapabilityRoundTripsThroughStorageExceptWhenUnknown() {
        XCTAssertEqual(
            ModelLanguageCapability(storageValue: ModelLanguageCapability.multilingual.storageValue!),
            .multilingual
        )
        XCTAssertEqual(
            ModelLanguageCapability(storageValue: ModelLanguageCapability.single(code: "en").storageValue!),
            .single(code: "en")
        )
        XCTAssertNil(ModelLanguageCapability.unknown.storageValue)
        XCTAssertNil(ModelLanguageCapability(storageValue: "nonsense"))
        XCTAssertNil(ModelLanguageCapability(storageValue: "single:"))
    }

    /// A pinned checkpoint describes itself. Whatever was last loaded does not get to overrule
    /// the catalog — only a folder we did not choose is answered by measurement.
    func testDeclaredCapabilityOutranksWhateverWasLastLoaded() {
        XCTAssertEqual(
            ModelLanguageResolver.capability(
                for: BuiltInModelID.parakeetEnglishV2.descriptor,
                detected: .multilingual
            ),
            .single(code: "en")
        )
        XCTAssertEqual(
            ModelLanguageResolver.capability(
                for: BuiltInModelID.whisperLargeV3Turbo.descriptor,
                detected: .single(code: "en")
            ),
            .multilingual
        )
        XCTAssertEqual(
            ModelLanguageResolver.capability(
                for: BuiltInModelID.whisperLocalFolder.descriptor,
                detected: .multilingual
            ),
            .multilingual
        )
    }

    // MARK: - Control shape

    func testEnglishOnlyModelOffersOneSettledOptionAndNoMenu() {
        let control = ModelLanguageResolver.control(
            for: BuiltInModelID.parakeetEnglishV2.descriptor,
            detected: nil,
            storedCode: nil
        )

        XCTAssertEqual(control?.options, [.language(code: "en")])
        XCTAssertEqual(control?.selection.title, "English")
        XCTAssertEqual(control?.allowsSelection, false)
    }

    func testMultilingualModelOffersAutoDetectPlusEveryLanguage() {
        let control = ModelLanguageResolver.control(
            for: BuiltInModelID.whisperLargeV3Turbo.descriptor,
            detected: nil,
            storedCode: nil
        )

        XCTAssertEqual(control?.options.count, 101)
        XCTAssertEqual(control?.options.first, .autoDetect)
        XCTAssertEqual(control?.selection, .autoDetect)
        XCTAssertEqual(control?.allowsSelection, true)
    }

    /// The menu leads with Auto-detect and ends with the full list; the user's own languages
    /// sit in between so a non-English speaker is not made to scroll on every change.
    func testMultilingualMenuLeadsWithAutoDetectAndEndsWithTheFullList() {
        let groups = ModelLanguageResolver.control(
            for: BuiltInModelID.whisperLargeV3Turbo.descriptor,
            detected: nil,
            storedCode: nil
        )?.optionGroups

        XCTAssertEqual(groups?.first, [.autoDetect])
        XCTAssertEqual(groups?.last, TranscriptionLanguageCatalog.allOptions)
        XCTAssertFalse(groups?.contains(where: \.isEmpty) ?? true, "an empty group would draw a stray divider")
    }

    /// Until a supplied folder has been loaded once there is nothing honest to show, so the
    /// row keeps its capability blurb and shows no control at all.
    func testUnmeasuredLocalFolderHasNoLanguageControl() {
        XCTAssertNil(
            ModelLanguageResolver.control(
                for: BuiltInModelID.whisperLocalFolder.descriptor,
                detected: nil,
                storedCode: nil
            )
        )
    }

    func testMeasuredLocalFolderTakesTheShapeOfWhatWasLoaded() {
        let multilingual = ModelLanguageResolver.control(
            for: BuiltInModelID.whisperLocalFolder.descriptor,
            detected: .multilingual,
            storedCode: nil
        )
        XCTAssertEqual(multilingual?.options.count, 101)
        XCTAssertEqual(multilingual?.allowsSelection, true)

        let englishOnly = ModelLanguageResolver.control(
            for: BuiltInModelID.whisperLocalFolder.descriptor,
            detected: .single(code: "en"),
            storedCode: nil
        )
        XCTAssertEqual(englishOnly?.selection.title, "English")
        XCTAssertEqual(englishOnly?.allowsSelection, false)
    }

    // MARK: - Read-time resolution

    func testStoredLanguageIsUsedWhenTheModelCanOfferIt() {
        let control = ModelLanguageResolver.control(
            for: BuiltInModelID.whisperLargeV3Turbo.descriptor,
            detected: nil,
            storedCode: "es"
        )

        XCTAssertEqual(control?.selection, .language(code: "es"))
        XCTAssertEqual(
            ModelLanguageResolver.decodingLanguageCode(
                for: BuiltInModelID.whisperLargeV3Turbo.descriptor,
                detected: nil,
                storedCode: "es"
            ),
            "es"
        )
    }

    func testUnofferableStoredLanguageFallsBackToTheModelsDefault() {
        XCTAssertEqual(
            ModelLanguageResolver.control(
                for: BuiltInModelID.whisperLocalFolder.descriptor,
                detected: .single(code: "en"),
                storedCode: "es"
            )?.selection,
            .language(code: "en")
        )

        XCTAssertEqual(
            ModelLanguageResolver.control(
                for: BuiltInModelID.whisperLargeV3Turbo.descriptor,
                detected: nil,
                storedCode: "not-a-language"
            )?.selection,
            .autoDetect
        )
    }

    /// The point of resolving on read rather than clearing on write: repointing a folder at an
    /// English-only checkpoint must not destroy the Spanish that was chosen for it.
    func testRepointingAFolderAndBackRestoresTheChosenLanguage() {
        let folder = BuiltInModelID.whisperLocalFolder.descriptor
        let stored = "es"

        XCTAssertEqual(
            ModelLanguageResolver.decodingLanguageCode(for: folder, detected: .multilingual, storedCode: stored),
            "es"
        )
        XCTAssertEqual(
            ModelLanguageResolver.decodingLanguageCode(for: folder, detected: .single(code: "en"), storedCode: stored),
            "en"
        )
        XCTAssertEqual(
            ModelLanguageResolver.decodingLanguageCode(for: folder, detected: .multilingual, storedCode: stored),
            "es"
        )
    }

    /// An unmeasured folder has no control and therefore no opinion, which has to reach the
    /// decoder as detection — the behaviour every existing install already has.
    func testUnmeasuredFolderStillAsksTheDecoderToDetect() {
        XCTAssertNil(
            ModelLanguageResolver.decodingLanguageCode(
                for: BuiltInModelID.whisperLocalFolder.descriptor,
                detected: nil,
                storedCode: "es"
            )
        )
    }

    // MARK: - The subtitle rule

    func testLanguageAppearsInExactlyOnePlacePerRow() {
        let ready = TranscriptionModelRowModel(
            model: BuiltInModelID.whisperLargeV3Turbo.descriptor,
            installState: .ready,
            isSelected: true
        )
        XCTAssertEqual(ready.statusLine(capabilityLabel: "Multilingual", hasLanguageControl: true), "Active")

        let notInstalled = TranscriptionModelRowModel(
            model: BuiltInModelID.whisperLargeV3Turbo.descriptor,
            installState: .notInstalled,
            isSelected: false
        )
        XCTAssertEqual(
            notInstalled.statusLine(capabilityLabel: "Multilingual", hasLanguageControl: false),
            "Not Installed · Multilingual"
        )

        let failed = TranscriptionModelRowModel(
            model: BuiltInModelID.whisperLocalFolder.descriptor,
            installState: .failed("boom"),
            isSelected: false
        )
        XCTAssertEqual(
            failed.statusLine(capabilityLabel: "Auto-detect", hasLanguageControl: false),
            "Needs Attention · Auto-detect"
        )

        let downloading = TranscriptionModelRowModel(
            model: BuiltInModelID.whisperLargeV3Turbo.descriptor,
            installState: .downloading(progress: 0.5, phase: "Downloading"),
            isSelected: false
        )
        XCTAssertEqual(
            downloading.statusLine(capabilityLabel: "Multilingual", hasLanguageControl: false),
            "Downloading · 50%"
        )
    }

    // MARK: - Persistence

    func testLanguageAndCapabilityPersistPerModel() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SettingsStore(userDefaults: defaults)

        XCTAssertNil(store.languageCode(for: .whisperLargeV3Turbo))

        store.setLanguageCode("de", for: .whisperLargeV3Turbo)
        store.setDetectedLanguageCapability(.multilingual, for: .whisperLocalFolder)

        // Per model, not per app: pinning Whisper to German leaves Parakeet alone.
        XCTAssertNil(store.languageCode(for: .parakeetEnglishV2))
        XCTAssertNil(store.detectedLanguageCapability(for: .whisperLargeV3Turbo))

        let reloaded = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.languageCode(for: .whisperLargeV3Turbo), "de")
        XCTAssertEqual(reloaded.detectedLanguageCapability(for: .whisperLocalFolder), .multilingual)

        // Clearing returns the model to auto-detect rather than storing a sentinel.
        reloaded.setLanguageCode(nil, for: .whisperLargeV3Turbo)
        XCTAssertNil(SettingsStore(userDefaults: defaults).languageCode(for: .whisperLargeV3Turbo))
    }

    /// Every dictation reloads the model and re-reports its capability. Writing an unchanged
    /// value would republish the store and redraw the settings pane on every transcription.
    func testRerecordingTheSameCapabilityDoesNotRepublish() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SettingsStore(userDefaults: defaults)

        var publishes = 0
        let token = store.objectWillChange.sink { _ in publishes += 1 }
        defer { token.cancel() }

        store.setDetectedLanguageCapability(.multilingual, for: .whisperLocalFolder)
        XCTAssertEqual(publishes, 1)

        store.setDetectedLanguageCapability(.multilingual, for: .whisperLocalFolder)
        XCTAssertEqual(publishes, 1, "an unchanged capability republished the store")

        store.setDetectedLanguageCapability(.single(code: "en"), for: .whisperLocalFolder)
        XCTAssertEqual(publishes, 2)
    }
}
