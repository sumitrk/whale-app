import Foundation

/// Which backend runs each built-in model. Callers ask for a model's backend and use it
/// directly: `backends[modelID].transcribe(modelID: modelID, …)`.
struct TranscriptionBackends: Sendable {
    static let shared = TranscriptionBackends()

    private let backends: [BuiltInModelGroup: any BuiltInTranscriptionBackend]

    init(_ backends: [BuiltInModelGroup: any BuiltInTranscriptionBackend] = [
        .parakeet: ParakeetTranscriptionBackend(),
        .whisper: WhisperTranscriptionBackend(),
        .apple: AppleSpeechTranscriptionBackend(),
    ]) {
        self.backends = backends
    }

    subscript(modelID: BuiltInModelID) -> any BuiltInTranscriptionBackend {
        let group = modelID.descriptor.group
        guard let backend = backends[group] else {
            fatalError("No transcription backend registered for \(group.rawValue)")
        }
        return backend
    }
}
