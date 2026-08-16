import SwiftUI

struct AIActionSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared
    @State private var apiKey = ""
    @State private var hasAPIKey = false
    @State private var keyError: String?

    var body: some View {
        Form {
            Section("OpenRouter") {
                LabeledContent("API key") {
                    Text(hasAPIKey ? (settings.openRouterKeyRejected ? "Rejected" : "Stored in Keychain") : "Not set")
                        .foregroundStyle(settings.openRouterKeyRejected ? .red : .secondary)
                }

                SecureField(hasAPIKey ? "Enter replacement key" : "Enter API key", text: $apiKey)
                HStack {
                    Button(hasAPIKey ? "Replace Key" : "Save Key") { saveKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasAPIKey {
                        Button("Clear", role: .destructive) { clearKey() }
                    }
                }
                if let keyError {
                    Text(keyError).foregroundStyle(.red)
                }

                LabeledContent("Pi runtime") {
                    Text(appState.piRuntime.status.label)
                        .foregroundStyle(runtimeColor)
                }
                if case .ready(let milliseconds) = appState.piRuntime.status {
                    Text("Pi 0.72.1 · \(PiRuntime.model) · reasoning off · started in \(milliseconds) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextEditor(text: $settings.aiActionMasterPrompt)
                    .font(.body)
                    .frame(minHeight: 150)
                Button("Reset to Default") {
                    settings.aiActionMasterPrompt = SettingsStore.defaultAIActionMasterPrompt
                }
            } header: {
                Text("Master Prompt")
            } footer: {
                Text("This prompt is appended inside Whale's protected insertion and context-safety instructions.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshKeyStatus() }
    }

    private var runtimeColor: Color {
        switch appState.piRuntime.status {
        case .ready: return .green
        case .unavailable: return .red
        default: return .secondary
        }
    }

    private func refreshKeyStatus() {
        hasAPIKey = (try? KeychainStore.string(for: .openRouterAPIKey))?.isEmpty == false
    }

    private func saveKey() {
        do {
            let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            try KeychainStore.set(value, for: .openRouterAPIKey)
            apiKey = ""
            settings.openRouterKeyRejected = false
            keyError = nil
            refreshKeyStatus()
            Task { try? await appState.piRuntime.restart() }
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func clearKey() {
        do {
            try KeychainStore.delete(.openRouterAPIKey)
            settings.openRouterKeyRejected = false
            appState.piRuntime.stop()
            refreshKeyStatus()
            keyError = nil
        } catch {
            keyError = error.localizedDescription
        }
    }
}
