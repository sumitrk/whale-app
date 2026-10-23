import Foundation

/// Whether the selected transcription model can run, and warming it before it's needed.
protocol CaptureModels: Sendable {
    func isInstalled(_ modelID: BuiltInModelID) async throws -> Bool
    /// Starts loading the model without waiting, so the load overlaps with the user talking.
    func warm(_ modelID: BuiltInModelID)
}

struct LocalCaptureModels: CaptureModels {
    let transcriber: LocalTranscriptionService

    func isInstalled(_ modelID: BuiltInModelID) async throws -> Bool {
        try await transcriber.isModelInstalled(modelID)
    }

    func warm(_ modelID: BuiltInModelID) {
        let transcriber = transcriber
        Task.detached(priority: .userInitiated) { try? await transcriber.prepareModel(modelID) }
    }
}
