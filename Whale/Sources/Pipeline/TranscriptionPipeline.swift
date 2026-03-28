import FluidAudio
import Foundation

// MARK: - Pipeline Stage Protocol

protocol PipelineStage: Sendable {
    var name: String { get }
    func process(_ context: PipelineContext) async throws -> PipelineContext
}

// MARK: - Pipeline Context

struct PipelineContext: Sendable {
    let originalWavURL: URL
    var wavURL: URL
    let modelID: BuiltInModelID
    let audioSource: AudioSource

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
}

// MARK: - Pipeline Result

struct PipelineResult: Sendable {
    let rawTranscript: String
    let processedTranscript: String
    let stagesExecuted: [String]
    let artifactsToDelete: [URL]
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
        audioSource: AudioSource
    ) async throws -> PipelineResult {
        var context = PipelineContext(
            originalWavURL: wavURL,
            wavURL: wavURL,
            modelID: modelID,
            audioSource: audioSource,
            temporaryArtifacts: [],
            rawTranscript: "",
            transcript: ""
        )

        var executedStages: [String] = []

        for stage in stages {
            context = try await stage.process(context)
            executedStages.append(stage.name)
        }

        return PipelineResult(
            rawTranscript: context.rawTranscript,
            processedTranscript: context.transcript,
            stagesExecuted: executedStages,
            artifactsToDelete: context.temporaryArtifacts
        )
    }
}
