import AppKit
import SwiftUI

/// Modifier-only keys that can be used solo as PTT keys.
/// All of them fire `flagsChanged`, not `keyDown`.
let pttModifierOnlyKeyCodes: Set<Int> = [
    54,  // Right Command
    55,  // Left Command
    56,  // Left Shift
    58,  // Left Option
    59,  // Left Control
    60,  // Right Shift
    61,  // Right Option
    62,  // Right Control
    63,  // Fn / Globe
]

/// Returns the modifier flag that goes up/down when a given modifier keyCode fires.
func modifierFlag(for keyCode: Int) -> NSEvent.ModifierFlags? {
    switch keyCode {
    case 54, 55: return .command
    case 56, 60: return .shift
    case 58, 61: return .option
    case 59, 62: return .control
    case 63:     return .function
    default:     return nil
    }
}

/// Human-readable name for modifier-only keys.
func modifierOnlyKeyName(_ keyCode: Int) -> String? {
    switch keyCode {
    case 54: return "Right ⌘"
    case 55: return "Left ⌘"
    case 56: return "Left ⇧"
    case 58: return "Left ⌥"
    case 59: return "Left ⌃"
    case 60: return "Right ⇧"
    case 61: return "Right ⌥"
    case 62: return "Right ⌃"
    case 63: return "Globe / Fn"
    default: return nil
    }
}

/// Key recorder for push-to-talk.
/// Accepts solo modifier keys (Right ⌘, Right ⌥, Fn, etc.) via flagsChanged
/// OR a regular modifier+key combo via keyDown.
struct PTTRecorderView: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    var startImmediately: Bool = false

    @State private var isRecording = false
    @State private var keyDownMonitor: Any?

    var body: some View {
        Button(isRecording ? "Press key…" : label) {
            isRecording ? stopRecording() : startRecording()
        }
        .buttonStyle(.bordered)
        .foregroundStyle(isRecording ? Color.orange : Color.primary)
        .onAppear { if startImmediately { startRecording() } }
        .onDisappear { stopRecording() }
    }

    private var label: String {
        SettingsStore.shared.keyLabel(keyCode: keyCode, modifiers: modifiers)
    }

    private func startRecording() {
        isRecording = true

        // Only capture modifier+key combos (⌘A, ⌥Space, etc.).
        // Solo modifier keys (Right ⌘, Fn…) are handled by the preset picker.
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil } // Escape = cancel
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                return event
            }
            keyCode = Int(event.keyCode)
            modifiers = Int(flags.rawValue)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = keyDownMonitor { NSEvent.removeMonitor(m); keyDownMonitor = nil }
    }
}
