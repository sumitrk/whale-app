import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Runs S1-mini on the GPU through MLX.
///
/// The model is held loaded between dictations — a 600 MB load per utterance would cost
/// more than the rewrite saves — but not indefinitely: a menu-bar app that idles all day
/// has no business keeping half a gigabyte of weights resident, so the model is dropped
/// after a quiet spell and on memory pressure, and reloaded on the next dictation.
actor S1CleanupEngine: TranscriptCleanupEngine {
    static let shared = S1CleanupEngine()

    /// Long enough that a working session never reloads, short enough that leaving the
    /// app open over lunch gives the memory back.
    static let idleUnloadDelay = Duration.seconds(300)

    /// MLX keeps a buffer cache that grows to whatever the largest recent allocation
    /// needed. On a 0.6B model at dictation lengths there is nothing to gain from a large
    /// one, and the app is not the only thing on this Mac.
    private static let gpuCacheLimit = 64 * 1024 * 1024

    private let installer: S1ModelInstaller
    private var container: ModelContainer?
    private var idleTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(installer: S1ModelInstaller = .shared) {
        self.installer = installer
        Task { await startWatchingMemoryPressure() }
    }

    // MARK: - TranscriptCleanupEngine

    func clean(_ transcript: String, options: TranscriptCleanupOptions) async throws -> String {
        let container = try await loadedContainer()
        let promptText = S1Prompt.prompt(for: transcript, options: options)

        let output = try await container.perform { context -> String in
            // The prompt already carries its own turn markers as literal text, so the
            // tokenizer must not add any of its own on top.
            let promptTokens = context.tokenizer.encode(text: promptText, addSpecialTokens: false)

            let parameters = GenerateParameters(
                maxTokens: S1Prompt.maxTokens(forPromptTokenCount: promptTokens.count),
                // Greedy. Normalization is a deterministic transformation and the model
                // ships `do_sample: false`; sampling here would only make the same
                // dictation come out differently twice.
                temperature: 0
            )

            var result = ""
            for await generation in try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(promptTokens)),
                parameters: parameters,
                context: context
            ) {
                if Task.isCancelled { break }
                if let chunk = generation.chunk {
                    result += chunk
                }
            }
            return result
        }

        try Task.checkCancellation()
        scheduleIdleUnload()
        return output
    }

    func warm() async {
        _ = try? await loadedContainer()
    }

    func unload() async {
        guard container != nil else { return }
        container = nil
        idleTask?.cancel()
        idleTask = nil
        MLX.GPU.clearCache()
        Self.log("Unloaded model")
    }

    // MARK: - Loading

    private func loadedContainer() async throws -> ModelContainer {
        if let container {
            scheduleIdleUnload()
            return container
        }

        guard await installer.isInstalled() else {
            throw TranscriptCleanupError.modelNotInstalled
        }

        let directory = await installer.modelDirectory
        Self.log("Loading model from \(directory.path)")

        MLX.GPU.set(cacheLimit: Self.gpuCacheLimit)

        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: S1TokenizerLoader()
        )

        container = loaded
        scheduleIdleUnload()
        Self.log("Model loaded")
        return loaded
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func startWatchingMemoryPressure() {
        guard memoryPressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { await self?.unload() }
        }
        source.resume()
        memoryPressureSource = source
    }

    private static func log(_ message: String) {
        let line = "[S1-mini] \(message)"
        print(line)
        DiagnosticLog.log(line)
    }
}

// MARK: - Tokenizer bridge

/// MLX and swift-transformers each define a `Tokenizer`, with the same job and different
/// argument labels. This is the whole of the difference between them.
private struct S1TokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        S1Tokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct S1Tokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    /// Never called. Whale builds S1's prompt by hand precisely so the empty think block
    /// the model needs is stated in the source rather than left to a template argument.
    func applyChatTemplate(
        messages _: [[String: any Sendable]],
        tools _: [[String: any Sendable]]?,
        additionalContext _: [String: any Sendable]?
    ) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}
