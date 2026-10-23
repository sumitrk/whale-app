import Foundation

/// Whether the selected transcription model can run, and warming it before it's needed.
protocol CaptureModels: Sendable {
    func isInstalled(_ modelID: BuiltInModelID) async throws -> Bool
    /// Starts loading the model without waiting, so the load overlaps with the user talking.
    func warm(_ modelID: BuiltInModelID)
}

struct LocalCaptureModels: CaptureModels {
    let backends: TranscriptionBackends

    func isInstalled(_ modelID: BuiltInModelID) async throws -> Bool {
        try await backends[modelID].isInstalled(modelID: modelID)
    }

    func warm(_ modelID: BuiltInModelID) {
        let backend = backends[modelID]
        Task.detached(priority: .userInitiated) { try? await backend.prepare(modelID: modelID) }
    }
}
