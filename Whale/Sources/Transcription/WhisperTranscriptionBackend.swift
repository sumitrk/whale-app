import CoreML
import FluidAudio
import Foundation
import WhisperKit

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

struct WhisperModelValidationResult: Sendable {
    let modelFolder: URL
    let tokenizerFolder: URL?
    let inferredModelName: String?
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

private struct WhisperRuntimeConfiguration: Sendable {
    let modelName: String?
    let modelRepo: String?
    let modelFolderPath: String
    let tokenizerFolder: URL?
}
