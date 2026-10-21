import AppKit
import SwiftUI

/// The system sidebar material, blurring what is behind the window (wallpaper, other windows).
/// It cannot see the grid: the blur for tiles under the column is `SidebarTileBlur`.
struct SidebarBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
