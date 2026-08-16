import AppKit
import SwiftUI

/// A button that records the next key combo pressed and saves it as keyCode + modifiers.
/// Click once to start recording, press Escape to cancel, or press any modifier+key to save.
struct KeyRecorderView: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "Press shortcut…" : keyLabel) {
            isRecording ? stopRecording() : startRecording()
        }
        .buttonStyle(.bordered)
        .foregroundStyle(isRecording ? Color.orange : Color.primary)
        .onDisappear { stopRecording() }
    }

    private var keyLabel: String {
        SettingsStore.shared.keyLabel(keyCode: keyCode, modifiers: modifiers)
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil } // Escape = cancel
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) || flags.contains(.option) || flags.contains(.control) else {
                return event // pass through unmodified keys
            }
            keyCode = Int(event.keyCode)
            modifiers = Int(flags.rawValue)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
