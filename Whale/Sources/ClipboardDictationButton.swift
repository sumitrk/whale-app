import SwiftUI

/// Starts and stops a Dictation from the menu when the shortcuts can't work. Observes the
/// capture module itself, so only this button redraws as a capture starts and stops.
struct ClipboardDictationButton: View {
    @ObservedObject var capture: CaptureController
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        if capture.phase.isRecording {
            Button("Stop dictation", systemImage: "stop.fill", action: stop)
        } else {
            Button("Start dictation (clipboard only)", systemImage: "mic.fill", action: start)
        }
    }
}
