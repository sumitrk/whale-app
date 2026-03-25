import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Floating panel

/// Non-activating HUD that floats above all windows near the cursor.
/// Shows a live audio waveform driven by the microphone RMS level.
final class RecordingIndicatorWindow: NSPanel {
    enum PasteHintReason {
        case manualPasteOnly
        case accessibilityMissing
    }

    static let shared = RecordingIndicatorWindow()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 36),
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        isOpaque           = false
        backgroundColor    = .clear
        hasShadow          = true
        ignoresMouseEvents = true
        level              = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior  = .none
    }

    func show(recorder: AudioRecorder) {
        // Rebuild the hosting view each show so onAppear fires fresh.
        let view = RecordingIndicatorView(recorder: recorder)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 48, height: 36)
        contentView = host
        setContentSize(host.frame.size)

        positionNearCursor()
        orderFront(nil)
    }

    func hide() {
        orderOut(nil)
        // Clear the hosting view to stop the timer when hidden.
        contentView = nil
    }

    /// Show a brief paste/accessibility nudge near the cursor.
    /// Dismissed automatically after 3 seconds.
    func showHint(reason: PasteHintReason) {
        let view = PasteHintView(reason: reason)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host
        setContentSize(size)

        positionNearCursor()
        orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.hide()
        }
    }

    private func positionNearCursor() {
        // 1. Try to place at the top-left corner of the focused input box.
        if let inputRect = focusedInputFrame() {
            clampAndSet(NSPoint(x: inputRect.minX, y: inputRect.maxY + 6))
            return
        }
        // 2. Fall back to just above the cursor.
        let mouse = NSEvent.mouseLocation
        clampAndSet(NSPoint(x: mouse.x - frame.width / 2, y: mouse.y + 18))
    }

    /// Returns the Cocoa-coordinate frame of the currently focused AX text element, or nil.
    private func focusedInputFrame() -> NSRect? {
        guard let snapshot = FocusedElementInspector.snapshot(),
              snapshot.isWritableTextTarget else { return nil }
        return snapshot.frame
    }

    private func clampAndSet(_ origin: NSPoint) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let sz = frame.size
        let x  = max(vf.minX + 4, min(origin.x, vf.maxX - sz.width  - 4))
        let y  = max(vf.minY + 4, min(origin.y, vf.maxY - sz.height - 4))
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI bar view

private struct RecordingIndicatorView: View {

    @ObservedObject var recorder: AudioRecorder

    private let barCount = 5
    private let minH: CGFloat = 3
    private let maxH: CGFloat = 20

    // Heights are the single source of truth — only the timer touches them.
    @State private var heights: [CGFloat] = Array(repeating: 3, count: 5)

    private let timer = Timer.publish(every: 0.07, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: heights[i])
                    .animation(.easeOut(duration: 0.12), value: heights[i])
            }
        }
        .frame(width: 36, height: 18)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.72)))
        .onReceive(timer) { _ in
            let level = recorder.micLevel
            guard level > 0.02 else {
                // Silent: collapse to flat without animation noise.
                if heights.first != minH {
                    heights = Array(repeating: minH, count: barCount)
                }
                return
            }
            // pow(x, 0.3) is very aggressive: quiet speech still looks dramatic.
            let boosted = pow(CGFloat(level), 0.8)
            for i in 0..<barCount {
                heights[i] = minH + (maxH - minH) * boosted * CGFloat.random(in: 0.55...1.0)
            }
        }
    }
}

// MARK: - Paste hint view

/// Shown briefly when auto-paste is not possible (no focused text input).
/// Lets the user know the transcript is ready on the clipboard.
private struct PasteHintView: View {
    let reason: RecordingIndicatorWindow.PasteHintReason

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if reason == .accessibilityMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 11, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                switch reason {
                case .manualPasteOnly:
                    HStack(spacing: 4) {
                        Text("Copied")
                            .foregroundColor(.white.opacity(0.55))
                        Text("·")
                            .foregroundColor(.white.opacity(0.3))
                        Text("⌘V to paste")
                            .foregroundColor(.white)
                    }

                case .accessibilityMissing:
                    Text("No Accessibility permission")
                        .foregroundColor(.white)
                    Text("Open Settings to grant access · ⌘V to paste")
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.72)))
    }
}
