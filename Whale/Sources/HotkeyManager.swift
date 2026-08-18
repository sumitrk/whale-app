import AppKit

enum HotkeyRegistrationMode {
    case full
    case localRecoveryOnly
    case stopped

    var includesGlobal: Bool {
        switch self {
        case .full: return true
        case .localRecoveryOnly, .stopped: return false
        }
    }

    var includesLocal: Bool {
        switch self {
        case .full, .localRecoveryOnly: return true
        case .stopped: return false
        }
    }
}

/// Manages Dictation, Transcript Mode, and AI Action shortcuts.
///
/// 1. **Toggle** (configurable, default ⌘⇧T): press once to start, press again to stop.
/// 2. **Push-to-talk** (configurable, default Fn): hold to record, release to stop.
///
/// Fn/Globe (keyCode 63) is a modifier key — detected via flagsChanged.
/// All other keys use keyDown + keyUp global+local monitors.
final class HotkeyManager {
    private var monitors: [Any] = []

    static func shouldCancelModifierOnlyAIAction(
        sourceUserData: Int64
    ) -> Bool {
        sourceUserData != contextCopyEventUserData
    }

    func rebuild(toggleKeyCode: Int,
                 toggleModifiers: NSEvent.ModifierFlags,
                 pttKeyCode: Int,
                 pttModifiers: NSEvent.ModifierFlags,
                 actionKeyCode: Int,
                 actionModifiers: NSEvent.ModifierFlags,
                 mode: HotkeyRegistrationMode,
                 onToggle: @escaping @MainActor () -> Void,
                 onPTTPress: @escaping @MainActor () -> Void,
                 onPTTRelease: @escaping @MainActor () -> Void,
                 onActionPress: @escaping @MainActor () -> Void,
                 onActionRelease: @escaping @MainActor () -> Void,
                 onActionCancel: @escaping @MainActor () -> Void) {
        stop()

        guard mode != .stopped else { return }

        installToggle(
            keyCode: toggleKeyCode,
            modifiers: toggleModifiers,
            mode: mode,
            action: onToggle
        )
        installPushToTalk(
            keyCode: pttKeyCode,
            modifiers: pttModifiers,
            mode: mode,
            onPress: onPTTPress,
            onRelease: onPTTRelease
        )
        installAIAction(
            keyCode: actionKeyCode,
            modifiers: actionModifiers,
            mode: mode,
            onPress: onActionPress,
            onRelease: onActionRelease,
            onCancel: onActionCancel
        )
    }

    private func installAIAction(
        keyCode: Int,
        modifiers: NSEvent.ModifierFlags,
        mode: HotkeyRegistrationMode,
        onPress: @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        if mode.includesGlobal,
           let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
               guard event.keyCode == 53 else { return }
               Task { @MainActor in onCancel() }
           }) {
            monitors.append(monitor)
        }
        if mode.includesLocal,
           let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
               guard event.keyCode == 53 else { return event }
               Task { @MainActor in onCancel() }
               return event
           }) {
            monitors.append(monitor)
        }

        if let flag = modifierFlag(for: keyCode) {
            var globalDown = false
            var globalCancelled = false
            var localDown = false
            var localCancelled = false

            if mode.includesGlobal {
                if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { event in
                    guard event.keyCode == UInt16(keyCode) else { return }
                    let nowDown = event.modifierFlags.contains(flag)
                    if nowDown && !globalDown {
                        globalDown = true
                        globalCancelled = false
                        Task { @MainActor in onPress() }
                    } else if !nowDown && globalDown {
                        globalDown = false
                        if !globalCancelled { Task { @MainActor in onRelease() } }
                    }
                }) { monitors.append(monitor) }

                if let monitor = NSEvent.addGlobalMonitorForEvents(
                    matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown],
                    handler: { event in
                        guard Self.shouldCancelModifierOnlyAIAction(
                            sourceUserData: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
                        ) else { return }
                        guard globalDown, !globalCancelled else { return }
                        globalCancelled = true
                        Task { @MainActor in onCancel() }
                    }
                ) { monitors.append(monitor) }
            }

            if mode.includesLocal {
                if let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
                    guard event.keyCode == UInt16(keyCode) else { return event }
                    let nowDown = event.modifierFlags.contains(flag)
                    if nowDown && !localDown {
                        localDown = true
                        localCancelled = false
                        Task { @MainActor in onPress() }
                    } else if !nowDown && localDown {
                        localDown = false
                        if !localCancelled { Task { @MainActor in onRelease() } }
                    }
                    return event
                }) { monitors.append(monitor) }

                if let monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown],
                    handler: { event in
                        guard Self.shouldCancelModifierOnlyAIAction(
                            sourceUserData: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
                        ) else { return event }
                        guard localDown, !localCancelled else { return event }
                        localCancelled = true
                        Task { @MainActor in onCancel() }
                        return event
                    }
                ) { monitors.append(monitor) }
            }
            return
        }

        var globalDown = false
        var localDown = false
        if mode.includesGlobal {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard event.keyCode == UInt16(keyCode), flags == modifiers, !globalDown else { return }
                globalDown = true
                Task { @MainActor in onPress() }
            }) { monitors.append(monitor) }
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: { event in
                guard event.keyCode == UInt16(keyCode), globalDown else { return }
                globalDown = false
                Task { @MainActor in onRelease() }
            }) { monitors.append(monitor) }
        }
        if mode.includesLocal {
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard event.keyCode == UInt16(keyCode), flags == modifiers, !localDown else { return event }
                localDown = true
                Task { @MainActor in onPress() }
                return nil
            }) { monitors.append(monitor) }
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { event in
                guard event.keyCode == UInt16(keyCode), localDown else { return event }
                localDown = false
                Task { @MainActor in onRelease() }
                return nil
            }) { monitors.append(monitor) }
        }
    }

    private func installToggle(keyCode: Int,
                               modifiers: NSEvent.ModifierFlags,
                               mode: HotkeyRegistrationMode,
                               action: @escaping @MainActor () -> Void) {
        if mode.includesGlobal,
           let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
               let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
               guard flags == modifiers, event.keyCode == UInt16(keyCode) else { return }
               Task { @MainActor in action() }
           } {
            monitors.append(monitor)
        }

        if mode.includesLocal,
           let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
               let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
               guard flags == modifiers, event.keyCode == UInt16(keyCode) else { return event }
               Task { @MainActor in action() }
               return nil
           } {
            monitors.append(monitor)
        }
    }

    private func installPushToTalk(keyCode: Int,
                                   modifiers: NSEvent.ModifierFlags,
                                   mode: HotkeyRegistrationMode,
                                   onPress: @escaping @MainActor () -> Void,
                                   onRelease: (@MainActor () -> Void)?) {
        if let flag = modifierFlag(for: keyCode) {
            var isGlobalDown = false
            var isLocalDown = false

            if mode.includesGlobal,
               let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                   guard event.keyCode == UInt16(keyCode) else { return }
                   let nowDown = event.modifierFlags.contains(flag)
                   if nowDown && !isGlobalDown {
                       isGlobalDown = true
                       Task { @MainActor in onPress() }
                   } else if !nowDown && isGlobalDown {
                       isGlobalDown = false
                       if let onRelease {
                           Task { @MainActor in onRelease() }
                       }
                   }
               } {
                monitors.append(monitor)
            }

            if mode.includesLocal,
               let monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                   guard event.keyCode == UInt16(keyCode) else { return event }
                   let nowDown = event.modifierFlags.contains(flag)
                   if nowDown && !isLocalDown {
                       isLocalDown = true
                       Task { @MainActor in onPress() }
                   } else if !nowDown && isLocalDown {
                       isLocalDown = false
                       if let onRelease {
                           Task { @MainActor in onRelease() }
                       }
                   }
                   return nil
               } {
                monitors.append(monitor)
            }
        } else {
            var isGlobalDown = false
            var isLocalDown = false

            if mode.includesGlobal {
                if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    guard flags == modifiers, event.keyCode == UInt16(keyCode), !isGlobalDown else { return }
                    isGlobalDown = true
                    Task { @MainActor in onPress() }
                } {
                    monitors.append(monitor)
                }

                if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { event in
                    guard event.keyCode == UInt16(keyCode), isGlobalDown else { return }
                    isGlobalDown = false
                    if let onRelease {
                        Task { @MainActor in onRelease() }
                    }
                } {
                    monitors.append(monitor)
                }
            }

            if mode.includesLocal {
                if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    guard flags == modifiers, event.keyCode == UInt16(keyCode), !isLocalDown else {
                        return event
                    }
                    isLocalDown = true
                    Task { @MainActor in onPress() }
                    return nil
                } {
                    monitors.append(monitor)
                }

                if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
                    guard event.keyCode == UInt16(keyCode) else { return event }
                    defer { isLocalDown = false }
                    guard isLocalDown else { return event }
                    if let onRelease {
                        Task { @MainActor in onRelease() }
                    }
                    return nil
                } {
                    monitors.append(monitor)
                }
            }
        }
    }

    // MARK: - Cleanup

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}
