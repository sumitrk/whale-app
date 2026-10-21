import SwiftUI
import Sparkle

struct GeneralSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @StateObject private var updaterState: UpdaterState

    init(updater: SPUUpdater?) {
        _updaterState = StateObject(wrappedValue: UpdaterState(updater: updater))
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    var body: some View {
        SettingsPageLayout(title: "General") {
            SettingsSection("System") {
                SettingsToggleRow(
                    "Launch at login",
                    subtitle: "Start Whale automatically when you sign in.",
                    icon: SettingsRowIcon("power", .settingsGreen),
                    isOn: $store.launchAtLogin
                )
            }

            SettingsSection("Updates") {
                SettingsValueRow("Version", value: appVersion)
                if let updater = updaterState.updater {
                    SettingsRow("Updates", icon: SettingsRowIcon("arrow.down.circle.fill", .settingsBlue)) {
                        Button("Check for updates…") { UpdateCheckAction.checkForUpdates(using: updater) }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .disabled(!updaterState.canCheckForUpdates)
                    }
                }
            }
        }
    }
}
