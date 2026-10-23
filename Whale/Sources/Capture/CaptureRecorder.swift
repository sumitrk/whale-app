import Foundation

/// The microphone and system audio, as the capture module needs them. `AudioRecorder` in the
/// app, a fake in tests.
@MainActor
protocol CaptureRecorder: AnyObject {
    var isRecording: Bool { get }
    var levelMeter: MicLevelMeter { get }
    /// Called once the microphone delivers usable audio.
    var onRecordingReady: (() -> Void)? { get set }
    func startRecording(captureSystemAudio: Bool) async throws
    func stopRecording() async throws -> RecordingResult
}

extension AudioRecorder: CaptureRecorder {}
