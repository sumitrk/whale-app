import AppKit
import SwiftUI

// From Spark's Compat.swift: the window and color helpers the settings components use, each
// falling back to an older API where the newer one doesn't exist.

extension View {
    /// The window's title removed from the title bar.
    @ViewBuilder func windowTitleRemoved() -> some View {
        if #available(macOS 15, *) {
            toolbar(removing: .title)
        } else {
            background(WindowTitleHider())
        }
    }

    @ViewBuilder func windowToolbarBackgroundHidden() -> some View {
        if #available(macOS 15, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            toolbarBackground(.hidden, for: .windowToolbar)
        }
    }

    /// No fade under the title bar where the page scrolls (macOS 26).
    @ViewBuilder func topScrollEdgeEffectHidden() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}

extension Color {
    /// `self` blended toward `other`.
    func mixed(with other: Color, by fraction: Double) -> Color {
        if #available(macOS 15, *) { return mix(with: other, by: fraction) }
        return Color(nsColor: NSColor(self).blended(withFraction: fraction, of: NSColor(other)) ?? NSColor(self))
    }
}

/// Before `toolbar(removing: .title)`: hides the title of the window it is in.
private struct WindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HidingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class HidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titleVisibility = .hidden
        }
    }
}
