import AVFoundation
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var micGranted: Bool = false
    @State private var axGranted:  Bool = false

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    icon:    "mic.fill",
                    label:   "Microphone",
                    detail:  "Required to capture your voice and system audio during recording.",
                    granted: micGranted,
                    action:  openMicSettings
                )

                PermissionRow(
                    icon:    "accessibility",
                    label:   "Accessibility",
                    detail:  "Required to detect focused text field and auto-paste transcript.",
                    granted: axGranted,
                    action:  openAccessibilitySettings
                )
            } footer: {
                Text("System audio capture shares the Microphone permission. Permissions are managed in System Settings → Privacy & Security.")
            }
        }
        .formStyle(.grouped)
        .onAppear { checkAll() }
    }

    // MARK: - Checks

    private func checkAll() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted  = AXIsProcessTrusted()
    }

    // MARK: - Deep links

    private func openMicSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        )
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
    }
}

// MARK: - Row

private struct PermissionRow: View {
    let icon:    String
    let label:   String
    let detail:  String
    let granted: Bool
    let action:  () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Button("Grant Access →", action: action)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(granted ? .green : .secondary)
            }
        }
    }
}
