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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                    .toggleStyle(.switch)
            }

            Section("About") {
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
    }
}
