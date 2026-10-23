import Foundation

/// Where the HUD draws: `HUDWindow` in the app, a recording fake in tests.
@MainActor
protocol HUDSurface: AnyObject {
    func present(_ content: HUDPillContent, dismissAfter: TimeInterval?)
    func hide()
}
