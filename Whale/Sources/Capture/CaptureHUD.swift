import Foundation

/// The HUD as the capture module reports to it.
@MainActor
protocol CaptureHUD: AnyObject {
    func update(_ event: HUDEvent)
}
