import AppKit
import Combine
import Foundation

@MainActor
final class AccessibilityController: ObservableObject {
    @Published private(set) var isTrusted = AXIsProcessTrusted()

    private var activationObserver: (any NSObjectProtocol)?
    private var pollTimer: Timer?
    private var isMonitoring = false
    private var pollDeadline = Date.distantPast
    private var recoveryAlertPresented = false

    func startMonitoring(promptOnLaunch: Bool) {
        guard !isMonitoring else { return }
        isMonitoring = true

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }

        // Do not invoke Apple's automatic prompt during normal relaunches.
        // For an existing install, a stale TCC record can make that prompt
        // appear repeatedly even while the old Settings row is enabled. The
        // explicit recovery dialog below explains the identity migration and
        // lets the user reset the record before opening Settings.
        let shouldOfferRecovery = promptOnLaunch
            && !isTestProcess
            && Self.shouldOfferIdentityRecovery(bundleIdentifier: Bundle.main.bundleIdentifier)
        refresh()

        if shouldOfferRecovery && !isTrusted {
            presentRecoveryAlertIfNeeded()
        }
    }

    func refresh(prompt: Bool = false) {
        let trusted: Bool
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        } else {
            trusted = AXIsProcessTrusted()
        }

        updateTrustState(trusted)

        if prompt && !trusted {
            startPolling()
        }
    }

    func requestPrompt() {
        refresh(prompt: true)
    }

    /// Explain and repair the one-time Accessibility break caused when an
    /// existing install moves from Apple Development to Developer ID signing.
    /// TCC intentionally requires the user to grant the new identity; the app
    /// can only reset its own stale record and open the system pane.
    private func presentRecoveryAlertIfNeeded() {
        guard !recoveryAlertPresented, !isTrusted else { return }
        recoveryAlertPresented = true

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTrusted else { return }

            let alert = NSAlert()
            alert.messageText = "Whale needs a one-time Accessibility refresh"
            alert.informativeText = "Whale does not currently have Accessibility access. If this is an update, macOS may still show an older Whale entry as enabled while blocking this version. Click Reset & Open Settings, then turn on the current Whale entry in Privacy & Security → Accessibility."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Reset & Open Settings")
            alert.addButton(withTitle: "Later")

            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                _ = self.resetAccessibilityGrant()
                self.openSystemAccessibilitySettingsAndWatch()
            }
        }
    }

    /// Reset only Whale's Accessibility decision. This cannot grant access;
    /// it clears a stale signing-identity record before the user re-enables it.
    @discardableResult
    private func resetAccessibilityGrant() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = [
            "reset",
            "Accessibility",
            Bundle.main.bundleIdentifier ?? "com.sumitrk.transcribe-meeting"
        ]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            DiagnosticLog.log("[Accessibility] Failed to reset stale grant: \(error.localizedDescription)")
            return false
        }
    }

    private var isTestProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || Bundle.main.bundleIdentifier?.hasSuffix("Tests") == true
    }

    func openSystemAccessibilitySettingsAndWatch() {
        // Register this exact binary with TCC before opening the pane. Opening
        // Settings immediately can steal focus and leave the app off the list.
        NSApp.activate(ignoringOtherApps: true)
        requestPrompt()
        startPolling()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            NSWorkspace.shared.open(Self.accessibilitySettingsURL)
        }
    }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    nonisolated static func shouldOfferIdentityRecovery(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.hasSuffix("Tests") else { return false }
        return !bundleIdentifier.hasSuffix(".dev")
    }

    nonisolated static var accessibilitySettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    }

    private func updateTrustState(_ trusted: Bool) {
        isTrusted = trusted

        if trusted {
            stopPolling()
        }
    }

    private func startPolling() {
        stopPolling()
        pollDeadline = Date().addingTimeInterval(15)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                if self.isTrusted || Date() >= self.pollDeadline {
                    self.stopPolling()
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
