import SwiftUI

struct AIActionSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            OpenRouterSection(
                connection: appState.openRouterConnection,
                runtime: appState.piRuntime
            )

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
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

/// One status row and one action. The key itself is never shown — a stored key
/// is a fact about the account, not a field to stare at — so the input only
/// appears when there is a key to enter.
private struct OpenRouterSection: View {
    @ObservedObject var connection: OpenRouterConnection
    @ObservedObject var runtime: PiRuntime
    /// Observed because the sticky rejected/out-of-credit flags live here and
    /// feed the status row.
    @ObservedObject private var settings = SettingsStore.shared

    @State private var isEditing = false
    @State private var apiKey = ""
    @State private var isSaving = false
    @State private var keyError: String?
    @State private var confirmingRemoval = false
    @FocusState private var keyFieldFocused: Bool

    var body: some View {
        Section("OpenRouter") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 8, height: 8)
                    Text(status.label)
                }
            }
            if let detail = status.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isEntering {
                SecureField("OpenRouter API key", text: $apiKey)
                    .focused($keyFieldFocused)
                    .onSubmit(submit)
                    .disabled(isSaving)
                if let keyError {
                    Text(keyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button(connection.hasKey ? "Done" : "Save Key", action: submit)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedKey.isEmpty || isSaving)
                    if connection.hasKey {
                        Button("Cancel", action: cancelEditing)
                            .keyboardShortcut(.cancelAction)
                            .disabled(isSaving)
                    }
                    if isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if !connection.hasKey {
                        Link("Get a key ↗", destination: OpenRouterKeyVerifier.keysPage)
                            .font(.caption)
                    }
                }
            } else {
                HStack {
                    Button("Replace Key", action: beginEditing)
                        .buttonStyle(.borderedProminent)
                    Button("Remove Key", role: .destructive) { confirmingRemoval = true }
                    if status.showsRetry {
                        Button("Retry", action: retry)
                    }
                    Spacer()
                    if status.showsTopUpLink {
                        Link("Top up ↗", destination: OpenRouterKeyVerifier.creditsPage)
                            .font(.caption)
                    }
                }
            }
        }
        .onAppear { connection.verifyNow() }
        .confirmationDialog(
            "Remove OpenRouter key?",
            isPresented: $confirmingRemoval
        ) {
            Button("Remove Key", role: .destructive, action: removeKey)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("AI Actions will stop working until you add a new one.")
        }
    }

    private var status: AIConnectionStatus {
        connection.status(runtime: runtime.status)
    }

    private var indicatorColor: Color {
        switch status.indicator {
        case .good: return .green
        case .bad: return .red
        case .neutral: return .secondary
        }
    }

    /// With no key the panel is useless until one is entered, so the field is
    /// there from the start. Hiding it only earns its keep when replacing.
    private var isEntering: Bool { isEditing || !connection.hasKey }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginEditing() {
        keyError = nil
        apiKey = ""
        isEditing = true
        keyFieldFocused = true
    }

    private func cancelEditing() {
        apiKey = ""
        keyError = nil
        isEditing = false
    }

    private func submit() {
        let value = trimmedKey
        guard !value.isEmpty, !isSaving else { return }
        isSaving = true
        keyError = nil
        Task {
            let result = await connection.save(key: value)
            isSaving = false
            switch result {
            case .saved:
                apiKey = ""
                isEditing = false
                try? await runtime.restart()
            case .failed(let message):
                // The stored key is untouched, so the old one still works.
                keyError = message
                keyFieldFocused = true
            }
        }
    }

    private func removeKey() {
        if let message = connection.remove() {
            keyError = message
            return
        }
        runtime.stop()
        apiKey = ""
        keyError = nil
        isEditing = false
    }

    private func retry() {
        connection.verifyNow(force: true)
        if case .unavailable = runtime.status {
            Task { try? await runtime.restart() }
        }
    }
}
