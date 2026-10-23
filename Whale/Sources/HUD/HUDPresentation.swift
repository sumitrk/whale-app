import Foundation

/// What the HUD puts on screen for an event.
enum HUDPresentation: Equatable {
    /// Shows the content, leaving by itself after `dismissAfter` (or on a click) when set.
    case show(HUDPillContent, dismissAfter: TimeInterval?)
    case hide
}
