import AppKit
import Combine

@MainActor
final class SettingsCoordinator: ObservableObject {
    @Published var selection: SettingsPage = .general
    private weak var settingsWindow: NSWindow?
    /// Set when Settings was asked for before its window existed, so the window comes to the
    /// front as soon as SwiftUI creates it.
    private var bringToFrontWhenAttached = false
    private var closeObserver: NSObjectProtocol?

    func registerSettingsWindow(_ window: NSWindow?) {
        settingsWindow = window
        observeClose(of: window)
        if bringToFrontWhenAttached, let window {
            bringToFrontWhenAttached = false
            Self.bringToFront(window)
        }
    }

    /// Shows Settings on `section` in front of whatever the user is in. Returns false when the
    /// window doesn't exist yet; the caller then opens it and it comes forward on attach.
    @discardableResult
    func focus(section: SettingsPage) -> Bool {
        selection = section
        // A menu-bar-only (accessory) app's activation is often refused while another app is
        // frontmost, which left Settings opening behind the current window. Like onboarding,
        // Whale is a regular app for as long as it shows a window the user asked for, which
        // lets it come to the front; it goes back to the menu bar when Settings closes.
        AppActivationPolicy.apply(needsForegroundApp: true)
        NSApp.activate(ignoringOtherApps: true)

        if let settingsWindow {
            Self.bringToFront(settingsWindow)
            return true
        }
        bringToFrontWhenAttached = true
        return false
    }

    private func observeClose(of window: NSWindow?) {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        guard let window else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppActivationPolicy.apply(needsForegroundApp: LaunchPresentation.current.needsForegroundApp)
            }
        }
    }

    private static func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
