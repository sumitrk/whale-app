import AVFoundation
import SwiftUI

struct PermissionsSettingsView: View {
    @EnvironmentObject private var accessibility: AccessibilityController
    @State private var micGranted: Bool = false

    var body: some View {
        Form {
            Section("Accessibility") {
                LabeledContent {
                    if accessibility.isTrusted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    } else {
                        HStack(spacing: 12) {
                            Text("Not Granted")
                                .foregroundStyle(.secondary)

                            Button("Open in System Settings") {
                                accessibility.openSystemAccessibilitySettingsAndWatch()
                            }

                            Button("Re-check") {
                                accessibility.refresh()
                            }
                        }
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility")
                            Text("Required for global shortcuts and auto-paste transcript.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "accessibility")
                            .foregroundStyle(accessibility.isTrusted ? .green : .secondary)
                    }
                }

                if !accessibility.isTrusted {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Global shortcuts and auto-paste are currently disabled until Accessibility permission is granted.")
                        Text("If \(appDisplayName) is not listed, click + in that pane and choose the app shown in Finder.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button("Show in Finder") {
                            accessibility.revealAppInFinder()
                        }
                    }
                }
            }

            Section {
                PermissionRow(
                    icon:    "mic.fill",
                    label:   "Microphone",
                    detail:  "Required to capture your voice and system audio during recording.",
                    granted: micGranted,
                    action:  openMicSettings
                )
            } header: {
                Text("Microphone")
            } footer: {
                Text("System audio capture shares the Microphone permission. Permissions are managed in System Settings → Privacy & Security.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear {
            checkMic()
            accessibility.refresh()
        }
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Whale"
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
                HStack(spacing: 12) {
                    Text("Not Granted")
                        .foregroundStyle(.secondary)
                    Button("Grant Access", action: action)
                }
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
