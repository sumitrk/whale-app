import AppKit

/// Manages two hotkey modes:
///
/// 1. **Toggle** (configurable, default ⌘⇧T): press once to start, press again to stop.
/// 2. **Push-to-talk** (configurable, default Fn): hold to record, release to stop.
///
/// Fn/Globe (keyCode 63) is a modifier key — detected via flagsChanged.
/// All other keys use keyDown + keyUp global+local monitors.
final class HotkeyManager {
    private var toggleGlobalMonitor:    Any?
    private var toggleLocalMonitor:     Any?
    private var pttFlagsGlobalMonitor:  Any?
    private var pttFlagsLocalMonitor:   Any?
    private var pttDownGlobalMonitor:   Any?
    private var pttDownLocalMonitor:    Any?
    private var pttUpGlobalMonitor:     Any?
    private var pttUpLocalMonitor:      Any?

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
        for m in [pttFlagsGlobalMonitor, pttFlagsLocalMonitor,
                  pttDownGlobalMonitor, pttDownLocalMonitor,
                  pttUpGlobalMonitor, pttUpLocalMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(m)
        }
        pttFlagsGlobalMonitor = nil; pttFlagsLocalMonitor = nil
        pttDownGlobalMonitor  = nil; pttDownLocalMonitor  = nil
        pttUpGlobalMonitor    = nil; pttUpLocalMonitor    = nil

        if let flag = modifierFlag(for: keyCode) {
            // Solo modifier key (Fn, Right ⌘, Right ⌥, etc.) — tracked via flagsChanged.
            // Both global (other apps frontmost) and local (our app frontmost) monitors needed.
            var isDown = false
            let handleFlags: (NSEvent) -> Void = { event in
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
            pttFlagsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handleFlags)
            pttFlagsLocalMonitor  = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                handleFlags(event); return event
            }
        } else {
            // Regular key — hold via keyDown + keyUp, both global and local monitors.
            var isDown = false
            let handleDown: (NSEvent) -> Void = { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags == modifiers, event.keyCode == UInt16(keyCode), !isDown else { return }
                isDown = true
                Task { @MainActor in onPress() }
            }
            let handleUp: (NSEvent) -> Void = { event in
                guard event.keyCode == UInt16(keyCode), isDown else { return }
                isDown = false
                Task { @MainActor in onRelease() }
            }
            pttDownGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handleDown)
            pttUpGlobalMonitor   = NSEvent.addGlobalMonitorForEvents(matching: .keyUp,   handler: handleUp)
            pttDownLocalMonitor  = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleDown(event); return event
            }
            pttUpLocalMonitor    = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
                handleUp(event); return event
            }
        }
    }

    // MARK: - Cleanup

    func stop() {
        [toggleGlobalMonitor, toggleLocalMonitor,
         pttFlagsGlobalMonitor, pttFlagsLocalMonitor,
         pttDownGlobalMonitor, pttDownLocalMonitor,
         pttUpGlobalMonitor, pttUpLocalMonitor]
            .compactMap { $0 }.forEach { NSEvent.removeMonitor($0) }
        toggleGlobalMonitor = nil; toggleLocalMonitor = nil
        pttFlagsGlobalMonitor = nil; pttFlagsLocalMonitor = nil
        pttDownGlobalMonitor = nil; pttDownLocalMonitor = nil
        pttUpGlobalMonitor = nil; pttUpLocalMonitor = nil
    }
}
