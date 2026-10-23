import Foundation

/// Whale's HUD. Callers report what happened (`HUDEvent`); this decides which content shows,
/// for how long, and when the pill leaves. `HUDWindow` draws it and places it.
@MainActor
final class HUD: CaptureHUD {
    static let shared = HUD(surface: HUDWindow.shared)

    static let pasteHintDuration: TimeInterval = 2
    static let errorDuration: TimeInterval = 4
    static let cancelledDuration: TimeInterval = 1

    private let surface: HUDSurface

    init(surface: HUDSurface) {
        self.surface = surface
    }

    func update(_ event: HUDEvent) {
        switch Self.presentation(for: event) {
        case .show(let content, let dismissAfter):
            surface.present(content, dismissAfter: dismissAfter)
        case .hide:
            surface.hide()
        }
    }

    /// The script: every rule about what the HUD shows lives here.
    static func presentation(for event: HUDEvent) -> HUDPresentation {
        switch event {
        case .preparing:
            .show(.processing, dismissAfter: nil)
        case .recording(let intent, let meter):
            // A meeting records without a pill in the way.
            intent == .transcriptMode ? .hide : .show(.recording(meter), dismissAfter: nil)
        case .processing(let intent):
            // The bars become the travelling wave while the words are worked out.
            intent == .transcriptMode ? .hide : .show(.processing, dismissAfter: nil)
        case .delivered(let pasteHint):
            if let pasteHint {
                .show(.pasteHint(pasteHint), dismissAfter: pasteHintDuration)
            } else {
                .hide
            }
        case .finished, .cancelled(replaced: true):
            .hide
        case .cancelled(replaced: false):
            .show(.message("Cancelled", isError: false), dismissAfter: cancelledDuration)
        case .failed(let message):
            .show(.message(message, isError: true), dismissAfter: errorDuration)
        }
    }
}
