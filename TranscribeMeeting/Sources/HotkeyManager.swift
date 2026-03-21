import AppKit

/// Manages two hotkey modes:
///
/// 1. **Toggle** (⌘⇧T): press once to start, press again to stop.
/// 2. **Push-to-talk** (Fn): hold to record, release to stop.
///
/// Both use NSEvent global monitors — no Accessibility permission required
/// to *detect* the keys. The events are observed but not consumed, so they
/// still reach the focused app (Fn has no standard meaning in other apps).
final class HotkeyManager {
    private var toggleMonitor: Any?
    private var pttMonitor: Any?

    // MARK: - Toggle mode (⌘⇧T)

    func start(onTrigger: @escaping @MainActor () -> Void) {
        toggleMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == [.command, .shift], event.keyCode == 17 else { return }
            Task { @MainActor in onTrigger() }
        }
    }

    // MARK: - Push-to-talk mode (Fn key, keyCode 63)

    func startPushToTalk(
        onPress:   @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) {
        pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            guard event.keyCode == 63 else { return }  // 63 = Fn/Globe key
            if event.modifierFlags.contains(.function) {
                Task { @MainActor in onPress() }
            } else {
                Task { @MainActor in onRelease() }
            }
        }
    }

    // MARK: - Cleanup

    func stop() {
        if let m = toggleMonitor { NSEvent.removeMonitor(m); toggleMonitor = nil }
        if let m = pttMonitor    { NSEvent.removeMonitor(m); pttMonitor    = nil }
    }
}
