import Foundation

/// The part of a capture that differs by intent: checks before it starts, work before the
/// microphone opens, and what to do with the text. Everything else, the capture module runs
/// the same way for every intent.
///
/// The AI Action's `complete` is where a multi-turn Agent Run grows (ADR-0003), which is why
/// it lives outside the capture module.
@MainActor
protocol CaptureIntentHandler: AnyObject {
    /// Refuses to start, synchronously, before anything is shown.
    func checkReady() throws
    /// After the History Entry exists, before the microphone opens.
    func willRecord(entry: CaptureEntry?) async throws
    func complete(_ transcript: CaptureTranscript, entry: CaptureEntry?) async throws -> CaptureCompletion
    /// Stops work `complete` has in flight.
    func cancel() async
}

extension CaptureIntentHandler {
    func checkReady() throws {}
    func willRecord(entry: CaptureEntry?) async throws {}
    func cancel() async {}
}
