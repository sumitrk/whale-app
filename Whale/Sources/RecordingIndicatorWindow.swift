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
/// - arriving and leaving are Core Animation springs on the pill's layer, which the render
///   server runs even while the main thread is blocked. Starting the microphone and playing the
///   start sound stall the main thread for 25–100ms at a time in the first quarter second,
///   which SwiftUI animations, stepped on the main thread, showed as dropped frames;
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
    /// Space between the bottom of the screen (above the Dock) and a bottom-centred pill.
    private static let bottomPadding: CGFloat = 24
    /// Room for the widest pill, a two-line message.
    private static let pillArea = NSSize(width: 400, height: 56)

    /// Arriving: up from 95% scale and 90% opacity.
    private static let appearDuration: TimeInterval = 0.25
    private static let appearOpacity: Float = 0.9
    private static let appearScale: CGFloat = 0.95
    private static let appearBounce: CGFloat = 0.32
    /// Leaving: down to 90% scale, fading out.
    private static let disappearDuration: TimeInterval = 0.1
    private static let disappearScale: CGFloat = 0.9
    /// Between contents, inside the pill: a SwiftUI animation, since it reshapes the view.
    private static let morph = Animation.spring(duration: 0.25, bounce: 0.18)

    private let model = HUDPillModel()
    private let container: NSView
    private let host: NSHostingView<RecordingPillView>

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
        container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        host = NSHostingView(rootView: RecordingPillView(model: model))
        // The window keeps its size whatever the pill shows; the pill moves inside it.
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
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

    /// Whether a presentation is on screen or on its way: true from `show…` until the pill has
    /// finished leaving.
    var hasContent: Bool { isAppearing || isShowing || isOnScreen }

    func show(meter: MicLevelMeter) {
        present(.recording(meter))
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
        animateOut()
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

        // Already up: the pill turns into the new content where it is. Except a new recording,
        // which arrives as a fresh pill even over a paste hint still showing: morphing is a
        // SwiftUI animation, stepped on the main thread just as the microphone starts and
        // stalls it, and the new recording may belong to a different field anyway.
        let startsFresh = content.meter != nil
        if isShowing, !startsFresh {
            withAnimation(Self.morph) { model.content = content }
            startTracking()
            return
        }

        // Swapped without animation, early enough that SwiftUI has drawn it by the time the
        // anchor is known; the Core Animation spring is the arrival.
        model.content = content
        if !isShowing { isAppearing = true }
        let place: @MainActor (HUDAnchor) -> Void = { [weak self] anchor in
            guard let self, self.presentationID == id else { return }
            self.currentAnchor = anchor
            self.updatePosition()
            self.startTracking()
            self.animateIn()
        }
        // At the bottom of the screen nothing depends on the focused field, so don't look for it.
        if position == .bottomCenter {
            place(.cursor)
        } else {
            resolveAnchor(timeout: Self.anchorTimeout, place)
        }
    }

    private var position: HUDPosition { SettingsStore.shared.hudPosition }

    private func animateIn() {
        isAppearing = false
        isShowing = true
        isOnScreen = true
        model.isVisible = true
        // Lay the new content out now, so the first frame on screen is this pill, not the last.
        host.layoutSubtreeIfNeeded()
        guard let layer = container.layer else {
            orderFront(nil)
            return
        }

        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        orderFront(nil)

        // Springs up from 95% scale and 90% opacity; Reduce Motion keeps only the opacity change.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fade = CASpringAnimation(perceptualDuration: Self.appearDuration, bounce: 0)
        fade.keyPath = "opacity"
        fade.fromValue = Self.appearOpacity
        fade.toValue = 1
        fade.duration = fade.settlingDuration
        layer.add(fade, forKey: "opacity")

        guard !reduceMotion else { return }
        let grow = CASpringAnimation(perceptualDuration: Self.appearDuration, bounce: Self.appearBounce)
        grow.keyPath = "transform"
        grow.fromValue = NSValue(caTransform3D: pillScale(Self.appearScale))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: "transform")
    }

    /// The reverse of appearing: down to 90% scale, fading all the way out, since the window is
    /// ordered out once it's done.
    private func animateOut() {
        guard let layer = container.layer else {
            finishHiding()
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let from = layer.presentation() ?? layer
        let endTransform = reduceMotion ? CATransform3DIdentity : pillScale(Self.disappearScale)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                // Unless a new presentation brought it back in the meantime.
                guard let self, !self.isShowing else { return }
                self.finishHiding()
            }
        }
        let fade = CASpringAnimation(perceptualDuration: Self.disappearDuration, bounce: 0)
        fade.keyPath = "opacity"
        fade.fromValue = from.opacity
        fade.toValue = 0
        fade.duration = fade.settlingDuration
        let shrink = CASpringAnimation(perceptualDuration: Self.disappearDuration, bounce: 0)
        shrink.keyPath = "transform"
        shrink.fromValue = NSValue(caTransform3D: from.transform)
        shrink.toValue = NSValue(caTransform3D: endTransform)
        shrink.duration = shrink.settlingDuration
        layer.opacity = 0
        layer.transform = endTransform
        layer.add(fade, forKey: "opacity")
        layer.add(shrink, forKey: "transform")
        CATransaction.commit()
    }

    private func finishHiding() {
        isOnScreen = false
        model.isVisible = false
        orderOut(nil)
        guard let layer = container.layer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    /// Scales the container about the pill's centre rather than the window's corner. The pill
    /// sits in one corner of the window, its size the SwiftUI view's own.
    private func pillScale(_ scale: CGFloat) -> CATransform3D {
        let bounds = container.bounds
        let fitting = host.fittingSize
        let width = min(max(fitting.width, 0), bounds.width)
        let height = min(max(fitting.height, 0), bounds.height)
        let alignment = model.alignment
        let midX: CGFloat = switch alignment.horizontal {
        case .leading: width / 2
        case .trailing: bounds.width - width / 2
        default: bounds.midX
        }
        // Layer coordinates run up from the bottom, so a top-aligned pill sits at the top.
        let midY: CGFloat = switch alignment.vertical {
        case .top: bounds.height - height / 2
        case .bottom: height / 2
        default: bounds.midY
        }
        // Transforms apply about the layer's anchor point (the bottom-left corner for a view's
        // layer), so move the pill's centre there, scale, and move it back.
        let anchor = container.layer?.anchorPoint ?? .zero
        let x = midX - anchor.x * bounds.width
        let y = midY - anchor.y * bounds.height
        var transform = CATransform3DMakeTranslation(x, y, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -x, -y, 0)
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
        if position == .nearInput, ticksUntilAnchorRefresh <= 0, !isRefreshingAnchor {
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
        if position == .bottomCenter {
            positionAtBottomCenter()
            return
        }
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

    /// Centred above the bottom of the screen the pointer is on; the pill grows outwards from
    /// the middle as its content changes.
    private func positionAtBottomCenter() {
        guard let screen = screen(containing: NSEvent.mouseLocation) else { return }
        let visibleFrame = screen.visibleFrame
        setAlignment(.bottom)
        setPillOrigin(NSPoint(
            x: visibleFrame.midX - pillSize.width / 2,
            y: visibleFrame.minY + Self.bottomPadding
        ))
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
