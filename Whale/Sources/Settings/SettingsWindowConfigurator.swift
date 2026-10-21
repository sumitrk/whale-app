import AppKit
import SwiftUI

/// Makes the Settings window behave like a normal one: resizable, with all three window buttons
/// active, and no toolbar (a Settings scene starts without minimize and zoom). From Spark, plus
/// what Whale needs on top: the frame autosave name, and handing the window to the coordinator
/// so the menu bar can bring it forward on a chosen page.
struct SettingsWindowConfigurator: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if window.frameAutosaveName != "SettingsWindow" {
                window.setFrameAutosaveName("SettingsWindow")
                onAttach(window)
            }
            window.styleMask.formUnion([.resizable, .miniaturizable])
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = true
            window.standardWindowButton(.zoomButton)?.isEnabled = true
            // The sidebar toggle floats in the toolbar; the page list needs no toggle.
            window.toolbar = nil
            window.titlebarSeparatorStyle = .none
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = false
            }
        }
    }
}
