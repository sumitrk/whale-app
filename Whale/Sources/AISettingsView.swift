import SwiftUI

struct AISettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var testState: TestState = .idle

    enum TestState { case idle, testing, ok, failed(String) }

    private let providers: [(id: String, label: String, model: String)] = [
        ("anthropic", "Anthropic (Claude)", "claude-sonnet-4-6"),
        ("openai",    "OpenAI (GPT-4o)",    "gpt-4o"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Enable AI summarisation", isOn: $store.aiEnabled)
            } footer: {
                Text("When enabled, each toggle-record session is cleaned up and summarised after transcription.")
            }

            if store.aiEnabled {
                Section("Provider") {
                    Picker("Provider", selection: $store.aiProvider) {
                        ForEach(providers, id: \.id) { p in
                            Text(p.label).tag(p.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    if let p = providers.first(where: { $0.id == store.aiProvider }) {
                        LabeledContent("Default model") {
                            Text(p.model)
                                .foregroundStyle(.secondary)
                                .font(.callout)
                        }
                    }
                }

                Section {
                    SecureField("Paste your API key…", text: $store.aiApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: store.aiApiKey) { testState = .idle }

                    HStack {
                        Button("Test connection") {
                            Task { await testKey() }
                        }
                        .disabled(store.aiApiKey.isEmpty || testState == .testing)

                        testStateView
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("Your API key is stored locally and never sent anywhere except the chosen provider.")
                }
            }
        }
        .formStyle(.grouped)
        .animation(.default, value: store.aiEnabled)
    }

    // MARK: - Test state view

    @ViewBuilder
    private var testStateView: some View {
        if case .testing = testState {
            ProgressView().scaleEffect(0.7)
        } else if case .ok = testState {
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        } else if case .failed(let msg) = testState {
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        }
    }

    // MARK: - Test

    private func testKey() async {
        testState = .testing
        do {
            let url = URL(string: "http://127.0.0.1:8765/summarise")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body: [String: String] = [
                "transcript": "Test.",
                "api_key":    store.aiApiKey,
                "provider":   store.aiProvider,
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 15

            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            testState = code == 200 ? .ok : .failed("HTTP \(code)")
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }
}

extension AISettingsView.TestState: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.testing, .testing), (.ok, .ok): return true
        case (.failed(let a), .failed(let b)):                  return a == b
        default: return false
        }
    }
}
