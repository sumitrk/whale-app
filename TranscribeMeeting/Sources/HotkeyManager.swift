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

    // MARK: - Toggle mode (configurable, default ⌘⇧T)

    func start(keyCode: Int, modifiers: NSEvent.ModifierFlags,
               onTrigger: @escaping @MainActor () -> Void) {
        if let m = toggleMonitor { NSEvent.removeMonitor(m) }
        toggleMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == modifiers, event.keyCode == UInt16(keyCode) else { return }
            Task { @MainActor in onTrigger() }
        }
    }

    // MARK: - Push-to-talk mode (Fn key, keyCode 63)

    func startPushToTalk(
        onPress:   @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) {
        var isFnDown = false
        pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            guard event.keyCode == 63 else { return }  // 63 = Fn/Globe key
            let nowDown = event.modifierFlags.contains(.function)
            if nowDown && !isFnDown {
                isFnDown = true
                Task { @MainActor in onPress() }
            } else if !nowDown && isFnDown {
                isFnDown = false
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
