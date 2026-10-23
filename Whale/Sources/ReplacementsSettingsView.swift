import SwiftUI

/// Phrases the user says, and the text Whale types for each instead.
struct ReplacementsSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var spoken = ""
    @State private var written = ""
    @FocusState private var focusesSpoken: Bool

    private var canAdd: Bool {
        !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !written.isEmpty
    }

    var body: some View {
        SettingsPageLayout(title: "Replacements") {
            SettingsSection(
                footer: "When a dictation contains the phrase, Whale types the replacement instead. Case doesn’t matter."
            ) {
                HStack(spacing: 10) {
                    TextField("When I say", text: $spoken)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusesSpoken)
                        .onSubmit(add)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    TextField("Type", text: $written)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(!canAdd)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)

                ForEach(store.replacements) { replacement in
                    ReplacementRow(replacement: replacement) { remove(replacement) }
                }
            }
        }
    }

    private func add() {
        let phrase = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAdd else { return }
        var replacements = store.replacements
        replacements.removeAll { $0.spoken.caseInsensitiveCompare(phrase) == .orderedSame }
        replacements.insert(TextReplacement(spoken: phrase, written: written), at: 0)
        withAnimation(.snappy) { store.replacements = replacements }
        spoken = ""
        written = ""
        focusesSpoken = true
    }

    private func remove(_ replacement: TextReplacement) {
        withAnimation(.snappy) { store.replacements.removeAll { $0.id == replacement.id } }
    }
}

private struct ReplacementRow: View {
    let replacement: TextReplacement
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: replacement.spoken)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("becomes")
            Text(verbatim: replacement.written)
                .fontWeight(.medium)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            Button("Remove", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }
}
