import ApplicationServices
import Sparkle
import SwiftUI

/// What the app has to put on screen for this launch.
///
/// Resolved before AppKit finishes launching, because the answer decides the activation
/// policy and the policy is the only thing that earns focus. Since macOS 14 an app
/// cannot take focus on demand — `NSApp.activate()` is a request the system drops unless
/// the app already holds the user's attention, and a menu-bar app holds none. What macOS
/// *does* do for free is activate a newly launched **foreground** app. So a launch that
/// owes the user a window announces it here and inherits that activation, instead of
/// trying to seize focus once the window is already up and unfocused.
enum LaunchPresentation: Equatable {
    /// First run. Onboarding is the app's own UI and the user has to work through it.
    case onboarding
    /// A stale TCC record is blocking this build; the recovery alert is modal, so an
    /// unfocused one is a dialog the user cannot dismiss.
    case accessibilityRecovery
    /// Nothing to show. The menu bar is the whole interface.
    case menuBarOnly

    static func resolve(
        hasCompletedOnboarding: Bool,
        isAccessibilityTrusted: Bool,
        offersIdentityRecovery: Bool
    ) -> LaunchPresentation {
        if !hasCompletedOnboarding { return .onboarding }
        if !isAccessibilityTrusted && offersIdentityRecovery { return .accessibilityRecovery }
        return .menuBarOnly
    }

    var needsForegroundApp: Bool { self != .menuBarOnly }

    @MainActor
    static var current: LaunchPresentation {
        resolve(
            hasCompletedOnboarding: SettingsStore.shared.hasCompletedOnboarding,
            isAccessibilityTrusted: AXIsProcessTrusted(),
            offersIdentityRecovery: AccessibilityController.offersIdentityRecovery
        )
    }
}

/// The app is a foreground app for exactly as long as it owes the user a window, and a
/// menu-bar app the rest of the time. One rule, applied at launch and again when the
/// window goes away.
enum AppActivationPolicy {
    static func policy(needsForegroundApp: Bool) -> NSApplication.ActivationPolicy {
        needsForegroundApp ? .regular : .accessory
    }

    @MainActor
    static func apply(needsForegroundApp: Bool) {
        NSApp.setActivationPolicy(policy(needsForegroundApp: needsForegroundApp))
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch completes, so a launch that owes a window *is* a foreground app
        // by the time macOS hands out the launch activation — and one that owes nothing
        // settles into the menu bar before the Dock ever sees an icon.
        AppActivationPolicy.apply(needsForegroundApp: LaunchPresentation.current.needsForegroundApp)
    }
}

@main
struct TranscribeMeetingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    @StateObject private var accessibilityController: AccessibilityController
    @StateObject private var settingsCoordinator: SettingsCoordinator
    private let updaterController: SPUStandardUpdaterController?

    init() {
        let accessibilityController = AccessibilityController()
        let settingsCoordinator = SettingsCoordinator()
        _accessibilityController = StateObject(wrappedValue: accessibilityController)
        _settingsCoordinator = StateObject(wrappedValue: settingsCoordinator)
        _appState = StateObject(
            wrappedValue: AppState(
                accessibility: accessibilityController
            )
        )
        if AppRuntimeInfo.current.sparkleDisabled {
            updaterController = nil
        } else {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
    }

    private var menuBarIconName: String {
        if appState.isRecording {
            return "record.circle.fill"
        }
        if !accessibilityController.isTrusted {
            return "exclamationmark.triangle.fill"
        }
        return "mic"
    }

    var body: some Scene {
        MenuBarExtra("Whale", systemImage: menuBarIconName) {
            MenuBarView(updater: updaterController?.updater)
                .environmentObject(appState)
                .environmentObject(accessibilityController)
                .environmentObject(settingsCoordinator)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(updater: updaterController?.updater)
                .environmentObject(appState)
                .environmentObject(accessibilityController)
                .environmentObject(settingsCoordinator)
        }
        .defaultSize(width: SettingsWindowMetrics.defaultWidth, height: SettingsWindowMetrics.defaultHeight)
        .windowResizability(.contentSize)
    }
}
