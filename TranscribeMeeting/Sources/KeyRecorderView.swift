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
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += keyCodeName(keyCode)
        return s
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

private func keyCodeName(_ code: Int) -> String {
    let map: [Int: String] = [
        0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
        11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2",
        20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8",
        29:"0", 31:"O", 32:"U", 34:"I", 35:"P", 37:"L", 38:"J", 39:"'", 40:"K",
        41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 49:"Space",
        51:"⌫", 53:"⎋", 123:"←", 124:"→", 125:"↓", 126:"↑"
    ]
    return map[code] ?? "?"
}
