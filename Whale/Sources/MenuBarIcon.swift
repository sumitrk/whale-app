import SwiftUI

/// The menu bar icon: the wave, or a warning while Accessibility is off.
///
/// It doesn't change while recording. Swapping a menu bar icon blocks the main thread for
/// 30–90ms in AppKit, and recording starts and stops are exactly when the HUD is animating;
/// the HUD and the system's microphone indicator already show that Whale is listening.
struct MenuBarIcon: View {
    @ObservedObject var accessibility: AccessibilityController

    var body: some View {
        if accessibility.isTrusted {
            Image("MenuBarIcon")
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}
