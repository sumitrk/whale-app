import AppKit
import SwiftUI

enum HUDAnchor: Equatable {
    case field(NSRect)
    case caret(NSRect)
    case cursor
}

enum HUDPlacementPolicy {
    private static let fieldRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]
    private static let caretAnchoredBundlePrefixes = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
    ]

    static func anchor(
        bundleIdentifier: String? = nil,
        role: String?,
        frame: NSRect?,
        caretFrame: NSRect? = nil,
        isWritable: Bool = true,
        isBrowserLike: Bool = false
    ) -> HUDAnchor {
        guard isWritable, let role, role != "AXWebArea" else { return .cursor }
        if isBrowserLike, !fieldRoles.contains(role) {
            return .cursor
        }

        let prefersCaret = bundleIdentifier.map { bundle in
            caretAnchoredBundlePrefixes.contains(where: bundle.hasPrefix)
        } ?? false
        if prefersCaret {
            guard let caretFrame, caretFrame.height > 0 else { return .cursor }
            return .caret(caretFrame)
        }
        if fieldRoles.contains(role), let frame, !frame.isEmpty {
            return .field(frame)
        }
        if let caretFrame, caretFrame.height > 0 {
            return .caret(caretFrame)
        }
        return .cursor
    }

    static func cursorOrigin(
        pointer: NSPoint,
        hudSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let gap: CGFloat = 12
        let x = pointer.x + gap + hudSize.width <= visibleFrame.maxX - 4
            ? pointer.x + gap
            : pointer.x - hudSize.width - gap
        let y = pointer.y - hudSize.height - gap >= visibleFrame.minY + 4
            ? pointer.y - hudSize.height - gap
            : pointer.y + gap
        return NSPoint(
            x: max(visibleFrame.minX + 4, min(x, visibleFrame.maxX - hudSize.width - 4)),
            y: max(visibleFrame.minY + 4, min(y, visibleFrame.maxY - hudSize.height - 4))
        )
    }
}

// MARK: - Floating panel

/// Non-activating HUD that floats above all windows near the cursor.
/// Shows a live audio waveform driven by the microphone RMS level.
@MainActor
final class RecordingIndicatorWindow: NSPanel {
    enum PasteHintReason: Equatable {
        case manualPasteOnly
        case accessibilityMissing

        var diagnosticName: String {
            switch self {
            case .manualPasteOnly:
                return "manualPasteOnly"
            case .accessibilityMissing:
                return "accessibilityMissing"
            }
        }
    }

    static let shared = RecordingIndicatorWindow()
    static let feedbackDismissalEvents: NSEvent.EventTypeMask = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]

    private var trackingTimer: Timer?
    private var currentAnchor: HUDAnchor = .cursor
    private var ticksUntilAnchorRefresh = 0
    private var globalDismissalMonitor: Any?
    private var localDismissalMonitor: Any?
    private var autoHideTask: Task<Void, Never>?
    private var presentationID = 0

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

        beginPresentation()
        fadeIn()
    }

    func showProcessing() {
        let view = ProcessingIndicatorView()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 48, height: 36)
        contentView = host
        setContentSize(host.frame.size)

        beginPresentation()
        fadeIn()
    }

    func hide() {
        guard contentView != nil else { return }
        presentationID &+= 1
        let hiddenPresentationID = presentationID
        stopPresentationObservers()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.presentationID == hiddenPresentationID else { return }
                self.orderOut(nil)
                // Clear the hosting view to stop the timer when hidden.
                self.contentView = nil
                self.alphaValue = 1
            }
        })
    }

    /// Show a brief paste/accessibility nudge.
    func showHint(reason: PasteHintReason) {
        let view = PasteHintView(reason: reason)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host
        setContentSize(size)

        beginPresentation(feedbackDuration: 2)
        orderFront(nil)
    }

    func showMessage(_ message: String, isError: Bool, duration: TimeInterval) {
        let view = StatusMessageView(message: message, isError: isError)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host
        setContentSize(size)
        beginPresentation(feedbackDuration: duration)
        orderFront(nil)
    }

    private func beginPresentation(feedbackDuration: TimeInterval? = nil) {
        presentationID &+= 1
        stopPresentationObservers()
        // A new presentation can replace a HUD that is still fading out.
        // Restore visibility before ordering the replacement to the front.
        alphaValue = 1
        currentAnchor = FocusedElementInspector.hudAnchor()
        ticksUntilAnchorRefresh = 30
        updatePosition()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.trackPosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer

        if let feedbackDuration {
            installDismissalMonitors()
            let id = presentationID
            autoHideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(feedbackDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.dismissFeedback(presentationID: id)
            }
        }
    }

    private func trackPosition() {
        ticksUntilAnchorRefresh -= 1
        if ticksUntilAnchorRefresh <= 0 {
            currentAnchor = FocusedElementInspector.hudAnchor()
            ticksUntilAnchorRefresh = 30
        }
        updatePosition()
    }

    private func updatePosition() {
        switch currentAnchor {
        case .field(let inputFrame):
            setClampedOrigin(
                NSPoint(x: inputFrame.minX, y: inputFrame.maxY + 6),
                on: screen(containing: NSPoint(x: inputFrame.midX, y: inputFrame.midY))
            )
        case .caret(let caretFrame):
            positionNearPointer(NSPoint(x: caretFrame.maxX, y: caretFrame.minY))
        case .cursor:
            positionNearPointer(NSEvent.mouseLocation)
        }
    }

    private func positionNearPointer(_ pointer: NSPoint) {
        guard let screen = screen(containing: pointer) else { return }
        setFrameOrigin(
            HUDPlacementPolicy.cursorOrigin(
                pointer: pointer,
                hudSize: frame.size,
                visibleFrame: screen.visibleFrame
            )
        )
    }

    private func setClampedOrigin(_ origin: NSPoint, on screen: NSScreen?) {
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let size = frame.size
        let x = max(visibleFrame.minX + 4, min(origin.x, visibleFrame.maxX - size.width - 4))
        let y = max(visibleFrame.minY + 4, min(origin.y, visibleFrame.maxY - size.height - 4))
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    private func installDismissalMonitors() {
        let id = presentationID
        globalDismissalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.feedbackDismissalEvents) { [weak self] _ in
            Task { @MainActor in
                self?.dismissFeedback(presentationID: id)
            }
        }
        localDismissalMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.feedbackDismissalEvents) { [weak self] event in
            Task { @MainActor in
                self?.dismissFeedback(presentationID: id)
            }
            return event
        }
    }

    private func dismissFeedback(presentationID id: Int) {
        guard presentationID == id else { return }
        hide()
    }

    private func stopPresentationObservers() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        autoHideTask?.cancel()
        autoHideTask = nil
        if let globalDismissalMonitor {
            NSEvent.removeMonitor(globalDismissalMonitor)
            self.globalDismissalMonitor = nil
        }
        if let localDismissalMonitor {
            NSEvent.removeMonitor(localDismissalMonitor)
            self.localDismissalMonitor = nil
        }
    }

    private func fadeIn() {
        alphaValue = 0
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }
}

private struct ProcessingIndicatorView: View {
    @State private var activeDot = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)
                    .opacity(index == activeDot ? 1 : 0.5)
            }
        }
        .frame(width: 36, height: 18)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.72)))
        .animation(.easeInOut(duration: 0.15), value: activeDot)
        .onReceive(timer) { _ in
            activeDot = (activeDot + 1) % 3
        }
    }
}

// MARK: - SwiftUI bar view

private struct RecordingIndicatorView: View {

    @ObservedObject var recorder: AudioRecorder

    private let barCount = 5
    private let minH: CGFloat = 3
    private let maxH: CGFloat = 20
    private let idleHeights: [CGFloat] = [8, 14, 20, 14, 8]

    @State private var heights: [CGFloat] = [8, 14, 20, 14, 8]

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
        .clipped()
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.72)))
        .onReceive(timer) { _ in
            let level = recorder.micLevel
            guard level > 0.02 else {
                if heights != idleHeights {
                    heights = idleHeights
                }
                return
            }
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
        .background(Capsule().fill(.black.opacity(0.72)))
    }
}

private struct StatusMessageView: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .foregroundStyle(isError ? .red : .secondary)
            Text(message)
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 360)
        .background(Capsule().fill(.black.opacity(0.78)))
    }
}
