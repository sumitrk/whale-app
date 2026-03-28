import FluidAudio
import Foundation

// MARK: - Pipeline Stage Protocol

protocol PipelineStage: Sendable {
    var name: String { get }
    func process(_ context: PipelineContext) async throws -> PipelineContext
}

// MARK: - Pipeline Context

struct PipelineContext: Sendable {
    let wavURL: URL
    let modelID: BuiltInModelID
    let audioSource: AudioSource

    /// Accumulated transcript text. Empty before the transcription stage runs,
    /// then progressively refined by subsequent stages (text cleanup, LLM, etc.).
    var transcript: String
}

// MARK: - Pipeline Result

struct PipelineResult: Sendable {
    let transcript: String
    let stagesExecuted: [String]
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
            wavURL: wavURL,
            modelID: modelID,
            audioSource: audioSource,
            transcript: ""
        )

        var executedStages: [String] = []

        for stage in stages {
            context = try await stage.process(context)
            executedStages.append(stage.name)
        }

        return PipelineResult(
            transcript: context.transcript,
            stagesExecuted: executedStages
        )
    }
}
