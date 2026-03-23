import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
            }

            Section {
                LabeledContent("Version") {
                    HStack {
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                        Button("Check for Updates") {
                            NSWorkspace.shared.open(
                                URL(string: "https://github.com/sumitrk/transcribe-meeting/releases")!
                            )
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
