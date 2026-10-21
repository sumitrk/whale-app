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
/// Shows a live audio waveform driven by the microphone level.
///
/// Built to stay smooth while the app is busy starting a recording:
/// - the focused-field lookup that decides where the pill sits runs off the main thread, with a
///   short timeout, instead of stalling the first frames of the fade;
/// - the fade and rise are Core Animation animations, which the render server runs even if the
///   main thread hiccups, rather than an `NSWindow` alpha animation stepped from the main thread;
/// - the recording view is built once and reused, so pressing the key doesn't build a new
///   SwiftUI hierarchy at the moment it needs to appear.
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

    /// How long to wait for the focused field before placing the pill at the pointer instead.
    /// Accessibility answers in a few milliseconds for most apps, but a busy app can take far
    /// longer, and the HUD must never wait on it.
    private static let anchorTimeout: TimeInterval = 0.12
    private static var inset: CGFloat { HUDShadowContainer<EmptyView>.inset }

    private let container: NSView
    private var recordingHost: NSHostingView<HUDShadowContainer<RecordingPillView>>?
    private weak var recordingMeter: MicLevelMeter?

    private var trackingTimer: Timer?
    private var currentAnchor: HUDAnchor = .cursor
    private var ticksUntilAnchorRefresh = 0
    private var isRefreshingAnchor = false
    private var globalDismissalMonitor: Any?
    private var localDismissalMonitor: Any?
    private var autoHideTask: Task<Void, Never>?
    private var presentationID = 0
    private var isShowing = false

    private init() {
        container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 52))
        container.wantsLayer = true
        super.init(
            contentRect: container.frame,
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       false
        )
        isOpaque           = false
        backgroundColor    = .clear
        hasShadow          = false
        ignoresMouseEvents = true
        level              = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior  = .none
        contentView        = container
    }

    func show(recorder: AudioRecorder) {
        let meter = recorder.levelMeter
        if recordingHost == nil || recordingMeter !== meter {
            recordingHost = NSHostingView(rootView: HUDShadowContainer { RecordingPillView(meter: meter) })
            recordingMeter = meter
        }
        present(recordingHost!, size: NSSize(width: 64, height: 52))
    }

    func showProcessing() {
        present(NSHostingView(rootView: HUDShadowContainer { ProcessingIndicatorView() }), size: NSSize(width: 64, height: 52))
    }

    func hide() {
        // Always invalidate the presentation: a quick tap can call this while the anchor
        // lookup is still running, and that presentation must not appear afterwards.
        presentationID &+= 1
        let hiddenPresentationID = presentationID
        stopPresentationObservers()
        guard isShowing else { return }
        isShowing = false

        guard let layer = container.layer else {
            finishHiding()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.presentationID == hiddenPresentationID else { return }
                self.finishHiding()
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Show a brief paste/accessibility nudge.
    func showHint(reason: PasteHintReason) {
        let host = NSHostingView(rootView: HUDShadowContainer { PasteHintView(reason: reason) })
        present(host, size: host.fittingSize, feedbackDuration: 2)
    }

    func showMessage(_ message: String, isError: Bool, duration: TimeInterval) {
        let host = NSHostingView(rootView: HUDShadowContainer { StatusMessageView(message: message, isError: isError) })
        present(host, size: host.fittingSize, feedbackDuration: duration)
    }

    // MARK: Presentation

    private func present(_ host: NSView, size: NSSize, feedbackDuration: TimeInterval? = nil) {
        presentationID &+= 1
        let id = presentationID
        stopPresentationObservers()

        if host.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            host.frame = NSRect(origin: .zero, size: size)
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
        }
        setContentSize(size)

        resolveAnchor(timeout: Self.anchorTimeout) { [weak self] anchor in
            guard let self, self.presentationID == id else { return }
            self.currentAnchor = anchor
            self.updatePosition()
            self.startTracking()
            if let feedbackDuration {
                self.scheduleFeedbackDismissal(after: feedbackDuration, presentationID: id)
            }
            self.animateIn()
        }
    }

    private func animateIn() {
        isShowing = true
        alphaValue = 1
        orderFront(nil)
        guard let layer = container.layer else { return }

        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let rise = CASpringAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -5
        rise.toValue = 0
        rise.mass = 1
        rise.stiffness = 320
        rise.damping = 26
        rise.duration = rise.settlingDuration
        layer.add(rise, forKey: "rise")
    }

    private func finishHiding() {
        orderOut(nil)
        container.subviews.forEach { $0.removeFromSuperview() }
        container.layer?.removeAllAnimations()
        container.layer?.opacity = 1
    }

    /// Looks up where the focused field is without blocking the main thread. Delivers the
    /// pointer anchor if the lookup is slower than `timeout`, and ignores the late answer.
    private func resolveAnchor(timeout: TimeInterval, _ deliver: @escaping @MainActor (HUDAnchor) -> Void) {
        var delivered = false
        let finish: @MainActor (HUDAnchor) -> Void = { anchor in
            guard !delivered else { return }
            delivered = true
            deliver(anchor)
        }
        Task.detached(priority: .userInitiated) {
            let anchor = FocusedElementInspector.hudAnchor()
            await MainActor.run { finish(anchor) }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            finish(.cursor)
        }
    }

    private func startTracking() {
        ticksUntilAnchorRefresh = 30
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.trackPosition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func scheduleFeedbackDismissal(after duration: TimeInterval, presentationID id: Int) {
        installDismissalMonitors()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismissFeedback(presentationID: id)
        }
    }

    // MARK: Position

    private func trackPosition() {
        ticksUntilAnchorRefresh -= 1
        if ticksUntilAnchorRefresh <= 0, !isRefreshingAnchor {
            ticksUntilAnchorRefresh = 30
            isRefreshingAnchor = true
            let id = presentationID
            Task.detached(priority: .utility) { [weak self] in
                let anchor = FocusedElementInspector.hudAnchor()
                await MainActor.run {
                    guard let self else { return }
                    self.isRefreshingAnchor = false
                    guard self.presentationID == id else { return }
                    self.currentAnchor = anchor
                }
            }
        }
        updatePosition()
    }

    private var pillSize: NSSize {
        NSSize(width: frame.width - Self.inset * 2, height: frame.height - Self.inset * 2)
    }

    private func updatePosition() {
        switch currentAnchor {
        case .field(let inputFrame):
            setClampedPillOrigin(
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
        setPillOrigin(
            HUDPlacementPolicy.cursorOrigin(
                pointer: pointer,
                hudSize: pillSize,
                visibleFrame: screen.visibleFrame
            )
        )
    }

    private func setClampedPillOrigin(_ origin: NSPoint, on screen: NSScreen?) {
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let size = pillSize
        let x = max(visibleFrame.minX + 4, min(origin.x, visibleFrame.maxX - size.width - 4))
        let y = max(visibleFrame.minY + 4, min(origin.y, visibleFrame.maxY - size.height - 4))
        setPillOrigin(NSPoint(x: x, y: y))
    }

    /// The window is larger than the pill by the shadow inset on every side.
    private func setPillOrigin(_ pillOrigin: NSPoint) {
        let origin = NSPoint(x: pillOrigin.x - Self.inset, y: pillOrigin.y - Self.inset)
        guard origin != frame.origin else { return }
        setFrameOrigin(origin)
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    // MARK: Feedback dismissal

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
