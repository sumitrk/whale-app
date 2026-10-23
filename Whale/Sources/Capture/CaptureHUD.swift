import Foundation

/// The HUD as the capture module drives it.
@MainActor
protocol CaptureHUD: AnyObject {
    func showRecording(_ meter: MicLevelMeter)
    func showProcessing()
    func hide()
    func showMessage(_ message: String, isError: Bool, duration: TimeInterval)
}

extension RecordingIndicatorWindow: CaptureHUD {
    func showRecording(_ meter: MicLevelMeter) {
        show(meter: meter)
    }
}
