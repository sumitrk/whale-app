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

    func testMissingSelectedModelKeyMigratesToParakeet() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("unknown-model", forKey: "selectedBuiltInModelID")

        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.selectedBuiltInModelID, .parakeetEnglishV2)
    }

    func testCatalogGroupsContainExpectedBuiltInModels() {
        XCTAssertEqual(BuiltInModelGroup.allCases, [.parakeet, .whisper])
        XCTAssertEqual(BuiltInModelCatalog.models(in: .parakeet).map(\.id), [.parakeetEnglishV2])
        XCTAssertEqual(
            BuiltInModelCatalog.models(in: .whisper).map(\.id),
            [.whisperLargeV3Turbo, .whisperLocalFolder]
        )
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

    func testSelectedModelTextComesFromDescriptor() {
        let descriptor = BuiltInModelID.whisperLargeV3Turbo.descriptor

        XCTAssertEqual(descriptor.markdownLabel, "Whisper Large V3 Turbo")
        XCTAssertTrue(descriptor.installationPrompt.contains("Whisper Large V3 Turbo"))

        let markdown = TranscriptMarkdownBuilder.build(
            date: Date(timeIntervalSince1970: 0),
            duration: 3,
            model: descriptor,
            transcript: "Hello world",
            formattedDate: "Jan 1, 1970 at 12:00 AM"
        )

        XCTAssertTrue(markdown.contains("**Model:** Whisper Large V3 Turbo"))
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

    private func makeTemporaryWhisperModelFolder(function: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Whale-\(function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
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
