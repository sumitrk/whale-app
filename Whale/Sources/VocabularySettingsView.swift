import SwiftUI

/// Names and jargon the user wants spelled their way.
struct VocabularySettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var draft = ""

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SettingsPageLayout(title: "Vocabulary") {
            SettingsSection(
                footer: "Whale types these exactly as written, and fixes close misses like “olama” for Ollama. Separate several words with commas."
            ) {
                HStack(spacing: 10) {
                    TextField("Add a name or word", text: $draft)
                        .textFieldStyle(.plain)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(trimmedDraft.isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)

                if !store.vocabulary.isEmpty {
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(store.vocabulary, id: \.self) { word in
                            VocabularyChip(word: word) { remove(word) }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private func add() {
        let words = draft
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return }
        var vocabulary = store.vocabulary
        for word in words where !vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            vocabulary.append(word)
        }
        withAnimation(.snappy) { store.vocabulary = vocabulary }
        draft = ""
    }

    private func remove(_ word: String) {
        withAnimation(.snappy) { store.vocabulary.removeAll { $0 == word } }
    }
}

private struct VocabularyChip: View {
    let word: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: word)
                .fontWeight(.medium)
            Button("Remove \(word)", systemImage: "xmark", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 6)
        .background(Color.settingsYellow.opacity(0.18), in: .capsule)
    }
}
