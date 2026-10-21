import SwiftUI

/// Gives a HUD pill room for its own shadow.
///
/// The panel's window shadow is off: AppKit computes it from the window's contents once, so it
/// sat at full strength while the pill was still fading in. Drawn here, the shadow fades and
/// moves with the pill.
struct HUDShadowContainer<Content: View>: View {
    static var inset: CGFloat { 8 }

    @ViewBuilder let content: Content

    var body: some View {
        content
            .compositingGroup()
            .shadow(color: .black.opacity(0.22), radius: 5, y: 1.5)
            .padding(Self.inset)
    }
}
