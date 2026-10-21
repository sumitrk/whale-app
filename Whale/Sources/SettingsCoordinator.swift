import AppKit
import Combine

@MainActor
final class SettingsCoordinator: ObservableObject {
    @Published var selection: SettingsPage = .general
    private weak var settingsWindow: NSWindow?

    func registerSettingsWindow(_ window: NSWindow?) {
        settingsWindow = window
    }

    @discardableResult
    func focus(section: SettingsPage) -> Bool {
        selection = section
        NSApp.activate()

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            settingsWindow.orderFrontRegardless()
            return true
        }
        return false
    }
}
