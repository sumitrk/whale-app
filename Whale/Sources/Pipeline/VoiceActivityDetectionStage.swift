import FluidAudio
import Foundation

struct VoiceActivityDetectionStage: PipelineStage {
    let name = "VAD"

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        guard context.audioSource == .microphone else {
            return context
        }

        let inputURL = context.wavURL
        let vadURL = inputURL
            .deletingPathExtension()
            .appendingPathExtension("vad")
            .appendingPathExtension("wav")

        let stats: VADStats
        do {
            stats = try VoiceActivityEditor.processWAV(inputURL: inputURL, outputURL: vadURL)
        } catch {
            print("[VAD] Stage error (falling back to original WAV): \(error.localizedDescription)")
            return context
        }

        if stats.skipped {
            print("[VAD] Skipped — \(stats.spanCount) spans, original \(String(format: "%.1f", stats.originalDuration))s")
            return context
        }

        print(
            "[VAD] Trimmed \(String(format: "%.1f", stats.originalDuration))s → "
            + "\(String(format: "%.1f", stats.retainedDuration))s "
            + "(\(stats.spanCount) spans, removed \(String(format: "%.1f", stats.removedDuration))s)"
        )

        var updated = context
        updated.wavURL = vadURL
        updated.temporaryArtifacts.append(vadURL)
        return updated
    }
}
