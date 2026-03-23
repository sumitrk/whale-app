import AppKit

/// Manages two hotkey modes:
///
/// 1. **Toggle** (configurable, default ⌘⇧T): press once to start, press again to stop.
/// 2. **Push-to-talk** (configurable, default Fn): hold to record, release to stop.
///
/// Fn/Globe (keyCode 63) is a modifier key — detected via flagsChanged.
/// All other keys use keyDown + keyUp global+local monitors.
final class HotkeyManager {
    private var toggleGlobalMonitor: Any?
    private var toggleLocalMonitor:  Any?
    private var pttFlagsMonitor:     Any?
    private var pttDownMonitor:      Any?
    private var pttUpMonitor:        Any?

    // MARK: - Toggle (configurable)

    func start(keyCode: Int, modifiers: NSEvent.ModifierFlags,
               onTrigger: @escaping @MainActor () -> Void) {
        if let m = toggleGlobalMonitor { NSEvent.removeMonitor(m); toggleGlobalMonitor = nil }
        if let m = toggleLocalMonitor  { NSEvent.removeMonitor(m); toggleLocalMonitor  = nil }

        toggleGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == modifiers, event.keyCode == UInt16(keyCode) else { return }
            Task { @MainActor in onTrigger() }
        }
        toggleLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == modifiers, event.keyCode == UInt16(keyCode) else { return event }
            Task { @MainActor in onTrigger() }
            return nil
        }
    }

    // MARK: - Push-to-talk (configurable)

    func startPushToTalk(keyCode: Int, modifiers: NSEvent.ModifierFlags,
                         onPress:   @escaping @MainActor () -> Void,
                         onRelease: @escaping @MainActor () -> Void) {
        if let m = pttFlagsMonitor { NSEvent.removeMonitor(m); pttFlagsMonitor = nil }
        if let m = pttDownMonitor  { NSEvent.removeMonitor(m); pttDownMonitor  = nil }
        if let m = pttUpMonitor    { NSEvent.removeMonitor(m); pttUpMonitor    = nil }

        if let flag = modifierFlag(for: keyCode) {
            // Solo modifier key (Fn, Right ⌘, Right ⌥, etc.) — tracked via flagsChanged
            var isDown = false
            pttFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                guard event.keyCode == UInt16(keyCode) else { return }
                let nowDown = event.modifierFlags.contains(flag)
                if nowDown && !isDown {
                    isDown = true
                    Task { @MainActor in onPress() }
                } else if !nowDown && isDown {
                    isDown = false
                    Task { @MainActor in onRelease() }
                }
            }
        } else {
            // Regular key — hold via keyDown + keyUp
            var isDown = false
            pttDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags == modifiers, event.keyCode == UInt16(keyCode), !isDown else { return }
                isDown = true
                Task { @MainActor in onPress() }
            }
            pttUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { event in
                guard event.keyCode == UInt16(keyCode), isDown else { return }
                isDown = false
                Task { @MainActor in onRelease() }
            }
        }
    }

    // MARK: - Cleanup

    func stop() {
        [toggleGlobalMonitor, toggleLocalMonitor,
         pttFlagsMonitor, pttDownMonitor, pttUpMonitor]
            .compactMap { $0 }.forEach { NSEvent.removeMonitor($0) }
        toggleGlobalMonitor = nil; toggleLocalMonitor = nil
        pttFlagsMonitor = nil; pttDownMonitor = nil; pttUpMonitor = nil
    }
}
