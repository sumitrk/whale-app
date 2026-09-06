import AppKit
import AVFoundation
import SwiftUI

struct PermissionsSettingsView: View {
    @EnvironmentObject private var accessibility: AccessibilityController
    @State private var micGranted: Bool = false

    var body: some View {
        Form {
            PermissionListSections(
                style: .settings,
                micGranted: micGranted,
                accessibilityGranted: accessibility.isTrusted,
                onMicAction: openMicSettings,
                onAccessibilityAction: accessibility.openSystemAccessibilitySettingsAndWatch,
                onAccessibilityRecheck: { accessibility.refresh() },
                onRevealInFinder: accessibility.revealAppInFinder
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            checkMic()
            accessibility.refresh()
        }
        // "Grant Access" hands the user off to System Settings, so the only reliable moment
        // to re-read the microphone status is when they come back — there is no notification
        // for the switch itself. Without this the red dot outlives the fix.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkMic()
        }
    }

    // MARK: - Checks

    private func checkMic() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Deep links

    private func openMicSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        )
    }
}

// MARK: - Shared list

/// The permission rows themselves, without a `Form` around them, so the settings pane and the
/// onboarding step present exactly the same rows — the same arrangement `ModelListSections`
/// uses for the model list.
///
/// The two contexts differ in behaviour, not in layout: on first run the OS will actually
/// prompt, so onboarding requests the permission directly and says so prominently; afterwards
/// macOS refuses to prompt again, so the settings pane can only open System Settings. That is
/// why the actions and the `style` are injected rather than decided here.
struct PermissionListSections: View {
    enum Style {
        /// Description hidden behind an info tooltip, plain bordered buttons.
        case settings
        /// Description always visible, prominent buttons — the step exists to explain why.
        case onboarding
    }

    let style: Style
    let micGranted: Bool
    let accessibilityGranted: Bool
    let onMicAction: () -> Void
    let onAccessibilityAction: () -> Void
    var onAccessibilityRecheck: (() -> Void)? = nil
    var onRevealInFinder: (() -> Void)? = nil

    var body: some View {
        Section {
            PermissionRow(
                descriptor: .microphone,
                style: style,
                granted: micGranted,
                actions: [PermissionAction(title: micActionTitle, run: onMicAction)]
            )

            PermissionRow(
                descriptor: .accessibility,
                style: style,
                granted: accessibilityGranted,
                actions: accessibilityActions,
                revealInFinder: onRevealInFinder
            )
        } footer: {
            if style == .settings {
                Text("System audio capture shares the Microphone permission. Permissions are managed in System Settings → Privacy & Security.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var micActionTitle: String {
        style == .onboarding ? "Grant" : "Grant Access"
    }

    private var accessibilityActions: [PermissionAction] {
        guard style == .settings else {
            return [PermissionAction(title: "Grant", run: onAccessibilityAction)]
        }

        // Primary action nearest the content, matching the model rows where the button that
        // changes what the row *is* sits left of the trailing control.
        var actions = [PermissionAction(title: "Open in System Settings", run: onAccessibilityAction)]
        if let recheck = onAccessibilityRecheck {
            actions.append(PermissionAction(title: "Re-check", run: recheck))
        }
        return actions
    }
}

// MARK: - Descriptor

/// One permission's fixed identity. Held in one place so the settings pane and the onboarding
/// step cannot describe the same permission two different ways, which is what they did before.
struct PermissionDescriptor {
    let title: String
    let symbol: String
    let description: String
    /// Shown only while the permission is missing, where the generic description is not enough
    /// to get someone unstuck.
    let troubleshooting: String?

    static let microphone = PermissionDescriptor(
        title: "Microphone",
        symbol: "mic.fill",
        description: "Required to capture your voice and system audio during recording.",
        troubleshooting: nil
    )

    static let accessibility = PermissionDescriptor(
        title: "Accessibility",
        symbol: "accessibility",
        description: "Required for global shortcuts and auto-paste transcript.",
        troubleshooting: "If \(PermissionDescriptor.appDisplayName) is not listed, click + in that pane and choose the app shown in Finder."
    )

    static var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Whale"
    }
}

struct PermissionAction {
    let title: String
    let run: () -> Void
}

// MARK: - Row

private struct PermissionRow: View {
    let descriptor: PermissionDescriptor
    let style: PermissionListSections.Style
    let granted: Bool
    let actions: [PermissionAction]
    var revealInFinder: (() -> Void)? = nil

    @State private var isShowingInfo = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            PermissionIcon(symbol: descriptor.symbol)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(descriptor.title)

                    // Settings keeps the reason one hover away; onboarding spells it out
                    // below, so a second copy in a tooltip would only be noise.
                    if style == .settings {
                        Image(systemName: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(isShowingInfo ? .primary : .secondary)
                            .accessibilityHidden(true)
                            .contentShape(Rectangle())
                            .onHover { isShowingInfo = $0 }
                            // A popover rather than `.help`: AppKit holds a tooltip back for
                            // about a second and offers no way to shorten it, which reads as
                            // the hint being broken. This one is up the moment the pointer
                            // lands on the badge.
                            .popover(isPresented: $isShowingInfo, arrowEdge: .bottom) {
                                Text(helpText)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: 260, alignment: .leading)
                                    .padding(12)
                            }
                    }
                }

                HStack(spacing: 5) {
                    Circle()
                        .fill(granted ? Color.green : Color.red)
                        .frame(width: 7, height: 7)

                    Text(granted ? "Granted" : "Not granted")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if style == .onboarding {
                    Text(descriptor.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The description carries the row's meaning even when it is only a tooltip, so
            // announce it rather than leaving VoiceOver with a bare title and a colour.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(descriptor.title)
            .accessibilityValue("\(granted ? "Granted" : "Not granted"). \(descriptor.description)")

            Spacer(minLength: 8)

            if !granted {
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                        button(for: action)
                    }
                }
                // Without this a long title takes the space it wants and squeezes the button
                // beside it down to a sliver.
                .fixedSize()
                .layoutPriority(1)
            }
        }
        .padding(.vertical, 4)
        .contextMenu { contextMenu }
    }

    @ViewBuilder
    private func button(for action: PermissionAction) -> some View {
        // Granting *is* the one thing the onboarding step exists for — Continue is gated on
        // it — so there it earns being the default action. Nothing on the settings pane does.
        if style == .onboarding {
            Button(action.title, action: action.run)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(action.title, action: action.run)
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if !granted, let revealInFinder {
            Button("Show in Finder", action: revealInFinder)
        }
    }

    private var helpText: String {
        guard !granted, let troubleshooting = descriptor.troubleshooting else {
            return descriptor.description
        }
        return "\(descriptor.description)\n\n\(troubleshooting)"
    }
}

// MARK: - Icon

/// The same tile the model rows use, and the same one System Settings puts down its sidebar —
/// but a fixed blue. In the model list the colour identifies a family; a permission has no
/// family to identify, and it must not encode grant state either, which is the dot's job.
private struct PermissionIcon: View {
    let symbol: String

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.blue)
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}
