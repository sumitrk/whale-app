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
///
/// One pill for every state: the recording bars, the processing wave, the paste hint and
/// messages are contents of the same `RecordingPillView`, which morphs from one to the next.
/// The window is sized for the widest pill and never resizes; the pill sits in the corner
/// nearest what it's anchored to.
///
/// Built to stay smooth while the app is busy starting a recording:
/// - the focused-field lookup that decides where the pill sits runs off the main thread, with a
///   short timeout, instead of stalling the first frames of the appearance;
/// - the pill's view is built once and reused, so pressing the key doesn't build a new
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
    /// Room for the widest pill, a two-line message.
    private static let pillArea = NSSize(width: 400, height: 56)

    private static let appear = Animation.spring(duration: 0.25, bounce: 0.32)
    private static let morph = Animation.spring(duration: 0.25, bounce: 0.18)
    private static let disappear = Animation.spring(duration: 0.1, bounce: 0)

    private let model = HUDPillModel()

    private var trackingTimer: Timer?
    private var currentAnchor: HUDAnchor = .cursor
    private var ticksUntilAnchorRefresh = 0
    private var isRefreshingAnchor = false
    private var globalDismissalMonitor: Any?
    private var localDismissalMonitor: Any?
    private var autoHideTask: Task<Void, Never>?
    private var presentationID = 0
    /// Asked for, waiting on the anchor lookup.
    private var isAppearing = false
    private var isShowing = false
    private var isOnScreen = false

    private init() {
        let size = NSSize(
            width: Self.pillArea.width + Self.inset * 2,
            height: Self.pillArea.height + Self.inset * 2
        )
        let host = NSHostingView(rootView: RecordingPillView(model: model))
        // The window keeps its size whatever the pill shows; the pill moves inside it.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        super.init(
            contentRect: host.frame,
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
        contentView        = host
    }

    /// Whether a presentation is on screen or on its way: true from `show…` until the pill has
    /// finished leaving.
    var hasContent: Bool { isAppearing || isShowing || isOnScreen }

    func show(recorder: AudioRecorder) {
        present(.recording(recorder.levelMeter))
    }

    /// The bars turn into a travelling wave while the words are worked out.
    func showProcessing() {
        present(.processing)
    }

    func hide() {
        // Always invalidate the presentation: a quick tap can call this while the anchor
        // lookup is still running, and that presentation must not appear afterwards.
        presentationID &+= 1
        isAppearing = false
        stopPresentationObservers()
        guard isShowing else {
            // Already leaving, its completion orders the window out; otherwise nothing is up.
            if !isOnScreen { finishHiding() }
            return
        }
        isShowing = false

        // The reverse of appearing: back down to 90% scale, fading all the way out, since the
        // window is ordered out once it's done.
        withAnimation(Self.disappear) {
            model.isLeaving = true
            model.isPresented = false
        } completion: { [weak self] in
            // Unless a new presentation brought it back in the meantime.
            guard let self, !self.isShowing else { return }
            self.finishHiding()
        }
    }

    /// Show a brief paste/accessibility nudge.
    func showHint(reason: PasteHintReason) {
        present(.pasteHint(reason), feedbackDuration: 2)
    }

    func showMessage(_ message: String, isError: Bool, duration: TimeInterval) {
        present(.message(message, isError: isError), feedbackDuration: duration)
    }

    // MARK: Presentation

    private func present(_ content: HUDPillContent, feedbackDuration: TimeInterval? = nil) {
        presentationID &+= 1
        let id = presentationID
        stopPresentationObservers()
        // From the moment it's asked for, so a click during the anchor lookup still dismisses it.
        if let feedbackDuration {
            scheduleFeedbackDismissal(after: feedbackDuration, presentationID: id)
        }

        // Already up: the pill turns into the new content where it is.
        if isShowing {
            withAnimation(Self.morph) { model.content = content }
            startTracking()
            return
        }

        if !isOnScreen {
            model.content = content
        } else {
            // Still leaving: come back from wherever it got to.
            withAnimation(Self.morph) { model.content = content }
        }
        isAppearing = true
        resolveAnchor(timeout: Self.anchorTimeout) { [weak self] anchor in
            guard let self, self.presentationID == id else { return }
            self.currentAnchor = anchor
            self.updatePosition()
            self.startTracking()
            self.animateIn()
        }
    }

    private func animateIn() {
        isAppearing = false
        isShowing = true
        isOnScreen = true
        orderFront(nil)
        // Springs up from 50% scale and 90% opacity; Reduce Motion keeps only the opacity change
        // (the view skips the scale).
        withAnimation(Self.appear) {
            model.isLeaving = false
            model.isPresented = true
        }
    }

    private func finishHiding() {
        isOnScreen = false
        orderOut(nil)
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

    private var pillSize: NSSize { Self.pillArea }

    private func updatePosition() {
        switch currentAnchor {
        case .field(let inputFrame):
            // Above the field, so the pill grows up and to the right from its corner.
            setAlignment(.bottomLeading)
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
        let origin = HUDPlacementPolicy.cursorOrigin(
            pointer: pointer,
            hudSize: pillSize,
            visibleFrame: screen.visibleFrame
        )
        // The corner of the pill area nearest the pointer, so the pill stays beside it.
        let isLeft = origin.x < pointer.x
        let isBelow = origin.y < pointer.y
        switch (isLeft, isBelow) {
        case (false, true): setAlignment(.topLeading)
        case (true, true): setAlignment(.topTrailing)
        case (false, false): setAlignment(.bottomLeading)
        case (true, false): setAlignment(.bottomTrailing)
        }
        setPillOrigin(origin)
    }

    /// Only on a change: this runs every frame, and each write would redraw the pill.
    private func setAlignment(_ alignment: Alignment) {
        guard model.alignment != alignment else { return }
        model.alignment = alignment
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
