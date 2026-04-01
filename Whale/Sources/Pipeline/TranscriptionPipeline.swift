import FluidAudio
import Foundation

// MARK: - Pipeline Stage Protocol

protocol PipelineStage: Sendable {
    var name: String { get }
    var isRecoverable: Bool { get }
    func process(_ context: PipelineContext) async throws -> PipelineContext
}

extension PipelineStage {
    var isRecoverable: Bool { false }
}

// MARK: - Pipeline Context

struct PipelineContext: Sendable {
    let originalWavURL: URL
    var wavURL: URL
    let modelID: BuiltInModelID
    let audioSource: AudioSource
    let outputMode: OutputMode
    let postProcessingSettings: TextCleanupSettings
    let focusedAppContext: FocusedAppContext?
    let progressHandler: @Sendable (String) -> Void

    /// Files created by pre-transcription stages (e.g. VAD-trimmed WAV)
    /// that should be deleted after the pipeline completes.
    var temporaryArtifacts: [URL]

    /// Raw transcript text produced by the transcription stage, before any
    /// post-processing. Stored separately so later stages can refine without
    /// losing the original.
    var rawTranscript: String

    /// Accumulated transcript text. Empty before the transcription stage runs,
    /// then progressively refined by subsequent stages (text cleanup, LLM, etc.).
    var transcript: String
    var warnings: [String]
    var didRunLocalLLM: Bool
    var didFallbackFromLocalLLM: Bool
}

// MARK: - Pipeline Result

struct PipelineResult: Sendable {
    let rawTranscript: String
    let processedTranscript: String
    let stagesExecuted: [String]
    let artifactsToDelete: [URL]
    let didRunLocalLLM: Bool
    let didFallbackFromLocalLLM: Bool
    let warnings: [String]
}

// MARK: - Pipeline

final class TranscriptionPipeline: @unchecked Sendable {
    private let stages: [PipelineStage]

    init(stages: [PipelineStage]) {
        self.stages = stages
    }

    /// Runs all stages sequentially, threading the context through each one.
    func process(
        wavURL: URL,
        modelID: BuiltInModelID,
        audioSource: AudioSource,
        outputMode: OutputMode,
        postProcessingSettings: TextCleanupSettings,
        focusedAppContext: FocusedAppContext?,
        progressHandler: @escaping @Sendable (String) -> Void = { _ in },
        stageObserver: @escaping @Sendable (String, PipelineContext) -> Void = { _, _ in }
    ) async throws -> PipelineResult {
        var context = PipelineContext(
            originalWavURL: wavURL,
            wavURL: wavURL,
            modelID: modelID,
            audioSource: audioSource,
            outputMode: outputMode,
            postProcessingSettings: postProcessingSettings,
            focusedAppContext: focusedAppContext,
            progressHandler: progressHandler,
            temporaryArtifacts: [],
            rawTranscript: "",
            transcript: "",
            warnings: [],
            didRunLocalLLM: false,
            didFallbackFromLocalLLM: false
        )

        var executedStages: [String] = []

        for stage in stages {
            do {
                context = try await stage.process(context)
                executedStages.append(stage.name)
                stageObserver(stage.name, context)
            } catch {
                if stage.isRecoverable {
                    context.warnings.append("\(stage.name): \(error.localizedDescription)")
                    if stage.name == LocalLLMCleanupStage.stageName {
                        context.didFallbackFromLocalLLM = true
                    }
                    continue
                }
                throw error
            }
        }

        return PipelineResult(
            rawTranscript: context.rawTranscript,
            processedTranscript: context.transcript,
            stagesExecuted: executedStages,
            artifactsToDelete: context.temporaryArtifacts,
            didRunLocalLLM: context.didRunLocalLLM,
            didFallbackFromLocalLLM: context.didFallbackFromLocalLLM,
            warnings: context.warnings
        )
    }
}
