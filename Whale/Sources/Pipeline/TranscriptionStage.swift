import FluidAudio
import Foundation

struct TranscriptionStage: PipelineStage {
    let name = "Transcription"
    let backends: TranscriptionBackends

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        let text = try await backends[context.modelID].transcribe(
            modelID: context.modelID,
            wavURL: context.wavURL,
            source: context.audioSource
        )

        var updated = context
        updated.rawTranscript = text
        updated.transcript = text
        return updated
    }
}
