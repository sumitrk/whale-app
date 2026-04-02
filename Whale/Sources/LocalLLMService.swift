import Foundation
import MLXLLM
import MLXLMCommon

enum LocalLLMError: LocalizedError {
    case unsupportedPlatform
    case insufficientMemory
    case modelNotInstalled(String)
    case emptyResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Local AI cleanup requires Apple Silicon."
        case .insufficientMemory:
            return "Not enough memory available for local AI cleanup."
        case .modelNotInstalled(let title):
            return "\(title) is not installed yet. Install it in Settings > Post-Processing before using AI cleanup."
        case .emptyResponse:
            return "The local cleanup model returned an empty response."
        case .timedOut:
            return "Local AI cleanup timed out."
        }
    }
}

actor LocalLLMService {
    static let shared = LocalLLMService()

    private var loadedModelID: LocalLLMModelID?
    private var loadedContainer: ModelContainer?
    private let cleanupAdditionalContext: [String: any Sendable] = [
        "enable_thinking": false
    ]

    static var isSupported: Bool {
#if arch(arm64)
        true
#else
        false
#endif
    }

    func isModelInstalled(_ modelID: LocalLLMModelID) async throws -> Bool {
        guard Self.isSupported else { return false }

        let directory = configuration(for: modelID).modelDirectory(hub: defaultHubApi)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }

        let hasConfig = FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path)
        let hasWeights = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?.contains(where: { $0.pathExtension == "safetensors" }) ?? false

        return hasConfig && hasWeights
    }

    func installModel(
        _ modelID: LocalLLMModelID,
        progressHandler: ModelInstallProgressHandler? = nil
    ) async throws {
        guard Self.isSupported else {
            throw LocalLLMError.unsupportedPlatform
        }

        _ = try await downloadModel(
            hub: defaultHubApi,
            configuration: configuration(for: modelID),
            progressHandler: { progress in
                progressHandler?(
                    ModelInstallProgress(
                        fractionCompleted: progress.fractionCompleted,
                        phase: Self.phaseLabel(for: progress)
                    )
                )
            }
        )
    }

    func cleanTranscript(
        transcript: String,
        focusedAppContext: FocusedAppContext?,
        cleanupLevel: CleanupLevel,
        cleanupPromptOverride: String,
        modelID: LocalLLMModelID,
        outputMode: OutputMode,
        timeout: TimeInterval?
    ) async throws -> String {
        guard Self.isSupported else {
            throw LocalLLMError.unsupportedPlatform
        }
        guard hasEnoughMemory else {
            throw LocalLLMError.insufficientMemory
        }

        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            return trimmedTranscript
        }

        let startedAt = Date()

        let generation = {
            try await self.generateResponse(
                transcript: trimmedTranscript,
                focusedAppContext: focusedAppContext,
                cleanupLevel: cleanupLevel,
                cleanupPromptOverride: cleanupPromptOverride,
                modelID: modelID,
                outputMode: outputMode
            )
        }

        let response: String
        if let timeout {
            response = try await withTimeout(seconds: timeout, operation: generation)
        } else {
            response = try await generation()
        }

        let sanitized = Self.sanitize(response)
        guard !sanitized.isEmpty else {
            throw LocalLLMError.emptyResponse
        }

        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        print("Local LLM Cleanup: model=\(modelID.rawValue) durationMs=\(milliseconds)")

        return sanitized
    }

    func prewarmModel(_ modelID: LocalLLMModelID) async throws {
        guard Self.isSupported else {
            throw LocalLLMError.unsupportedPlatform
        }
        guard try await isModelInstalled(modelID) else {
            throw LocalLLMError.modelNotInstalled(modelID.descriptor.title)
        }
        if loadedModelID == modelID, loadedContainer != nil {
            return
        }

        _ = try await generateResponse(
            transcript: "ok",
            focusedAppContext: nil,
            cleanupLevel: .medium,
            cleanupPromptOverride: "",
            modelID: modelID,
            outputMode: .paste,
            maxTokensOverride: 8
        )
    }

    func unloadModel() {
        loadedContainer = nil
        loadedModelID = nil
    }

    private var hasEnoughMemory: Bool {
        ProcessInfo.processInfo.physicalMemory >= 8_000_000_000
    }

    private func generateResponse(
        transcript: String,
        focusedAppContext: FocusedAppContext?,
        cleanupLevel: CleanupLevel,
        cleanupPromptOverride: String,
        modelID: LocalLLMModelID,
        outputMode: OutputMode,
        maxTokensOverride: Int? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        let container = try await modelContainer(for: modelID)
        let instructions = PromptBuilder.buildCleanupInstructions(
            focusedAppContext: focusedAppContext,
            cleanupLevel: cleanupLevel,
            customInstructions: cleanupPromptOverride
        )
        let prompt = PromptBuilder.buildCleanupUserPrompt(transcript: transcript)
        let maxTokens = maxTokensOverride
            ?? PromptBuilder.maxTokens(
                for: prompt,
                cleanupLevel: cleanupLevel,
                outputMode: outputMode
            )
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.0,
                topP: 1.0,
                prefillStepSize: 128
            ),
            additionalContext: cleanupAdditionalContext
        )
        return try await session.respond(to: prompt)
    }

    private func modelContainer(for modelID: LocalLLMModelID) async throws -> ModelContainer {
        if loadedModelID == modelID, let loadedContainer {
            return loadedContainer
        }

        let container = try await loadModelContainer(
            id: modelID.descriptor.repoID,
            progressHandler: { _ in }
        )
        loadedModelID = modelID
        loadedContainer = container
        return container
    }

    private func configuration(for modelID: LocalLLMModelID) -> ModelConfiguration {
        ModelConfiguration(id: modelID.descriptor.repoID)
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LocalLLMError.timedOut
            }

            guard let result = try await group.next() else {
                throw LocalLLMError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    private static func sanitize(_ response: String) -> String {
        var sanitized = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if let thinkRegex = try? NSRegularExpression(pattern: "(?is)<think>.*?</think>") {
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = thinkRegex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "")
        }

        if let promptEchoRegex = try? NSRegularExpression(
            pattern: #"(?im)^(clean(?:up)? level:.*|text to clean:.*|app name:.*|bundle id:.*|return only the cleaned text.*|you are cleaning up dictated text.*|clean up dictated text for insertion into another app\.)\s*$"#
        ) {
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = promptEchoRegex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "")
        }

        sanitized = sanitized
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if sanitized.hasPrefix("\""), sanitized.hasSuffix("\""), sanitized.count >= 2 {
            sanitized.removeFirst()
            sanitized.removeLast()
        }

        let leakedLabelPatterns = [
            #"(?im)^\s*(codex|assistant)\s*[:：-]?\s*"#,
            #"(?im)\n\s*(codex|assistant)\s*[:：-]?\s*"#
        ]
        for pattern in leakedLabelPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
                sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "\n")
            }
        }

        sanitized = sanitized
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if sanitized.caseInsensitiveCompare("codex") == .orderedSame
            || sanitized.caseInsensitiveCompare("assistant") == .orderedSame {
            sanitized = ""
        }

        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func phaseLabel(for progress: Progress) -> String {
        if let description = progress.localizedAdditionalDescription, !description.isEmpty {
            return description
        }
        if let localized = progress.localizedDescription as String?, !localized.isEmpty {
            return localized
        }
        return "Downloading model files…"
    }
}

@MainActor
final class LocalLLMModelStore: ObservableObject {
    static let shared = LocalLLMModelStore(service: .shared)

    @Published private(set) var installStates: [LocalLLMModelID: NativeModelInstallState]

    private let service: LocalLLMService
    private var installTasks: [LocalLLMModelID: Task<Void, Never>] = [:]

    init(service: LocalLLMService) {
        self.service = service
        self.installStates = Dictionary(
            uniqueKeysWithValues: LocalLLMModelCatalog.allModels.map { ($0.id, .checking) }
        )
    }

    var selectedModelID: LocalLLMModelID? {
        SettingsStore.shared.selectedLocalLLMModelID
    }

    func installState(for modelID: LocalLLMModelID) -> NativeModelInstallState {
        installStates[modelID] ?? .checking
    }

    func isReady(for modelID: LocalLLMModelID) -> Bool {
        if case .ready = installState(for: modelID) {
            return true
        }
        return false
    }

    func refresh() {
        guard installTasks.isEmpty else { return }
        Task { await refreshNow() }
    }

    func refreshNow() async {
        guard LocalLLMService.isSupported else {
            for model in LocalLLMModelCatalog.allModels {
                installStates[model.id] = .failed(LocalLLMError.unsupportedPlatform.errorDescription ?? "Unsupported platform")
            }
            return
        }

        for model in LocalLLMModelCatalog.allModels {
            await refresh(model.id)
        }
    }

    func refresh(_ modelID: LocalLLMModelID) async {
        guard !isDownloading(modelID) else { return }

        setInstallState(.checking, for: modelID)
        do {
            let isInstalled = try await service.isModelInstalled(modelID)
            setInstallState(isInstalled ? .ready : .notInstalled, for: modelID)
        } catch {
            setInstallState(.failed(error.localizedDescription), for: modelID)
        }
    }

    func install(_ modelID: LocalLLMModelID) {
        guard !isDownloading(modelID) else { return }

        installTasks[modelID]?.cancel()
        setInstallState(.downloading(progress: nil, phase: "Preparing model download…"), for: modelID)

        installTasks[modelID] = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor [weak self] in
                    self?.installTasks[modelID] = nil
                }
            }

            do {
                try await service.installModel(modelID) { progress in
                    Task { @MainActor [weak self] in
                        self?.setInstallState(
                            .downloading(progress: progress.fractionCompleted, phase: progress.phase),
                            for: modelID
                        )
                    }
                }

                await MainActor.run {
                    self.setInstallState(
                        .downloading(progress: 1.0, phase: "Preparing model for first use…"),
                        for: modelID
                    )
                }

                try await service.prewarmModel(modelID)
                await service.unloadModel()

                if !Task.isCancelled {
                    await MainActor.run {
                        self.setInstallState(.ready, for: modelID)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.setInstallState(.failed(error.localizedDescription), for: modelID)
                    }
                }
            }
        }
    }

    private func isDownloading(_ modelID: LocalLLMModelID) -> Bool {
        if case .downloading = installState(for: modelID) {
            return true
        }
        return false
    }

    private func setInstallState(_ state: NativeModelInstallState, for modelID: LocalLLMModelID) {
        installStates[modelID] = state
    }
}
