import Combine
import SwiftUI
import Sparkle

@MainActor
private final class SettingsUpdaterState: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    let updater: SPUUpdater?
    private var cancellable: AnyCancellable?

    init(updater: SPUUpdater?) {
        self.updater = updater
        guard let updater else { return }

        cancellable = updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
            }
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @StateObject private var updaterState: SettingsUpdaterState

    init(updater: SPUUpdater?) {
        _updaterState = StateObject(wrappedValue: SettingsUpdaterState(updater: updater))
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    var body: some View {
        Form {
            Section("System") {
                Toggle(isOn: $store.launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("Start Whale automatically when you sign in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            Section("Updates") {
                LabeledContent("Version", value: appVersion)

                if let updater = updaterState.updater {
                    LabeledContent("Updates") {
                        Button("Check for Updates…") {
                            updater.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!updaterState.canCheckForUpdates)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
