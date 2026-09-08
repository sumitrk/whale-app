import AppKit
import Combine

@MainActor
final class SettingsCoordinator: ObservableObject {
    @Published var selection: SettingsSection = .general
    private weak var settingsWindow: NSWindow?

    func registerSettingsWindow(_ window: NSWindow?) {
        settingsWindow = window
    }

    @discardableResult
    func focus(section: SettingsSection) -> Bool {
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
