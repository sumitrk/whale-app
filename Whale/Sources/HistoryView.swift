import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject private var controller = HistoryController.shared
    @State private var query = ""
    @State private var entries: [HistoryEntry] = []
    @State private var selectedID: UUID?
    @State private var selectedEntry: HistoryEntry?
    @State private var storageBytes: Int64 = 0
    @State private var showingClearConfirmation = false

    var body: some View {
        Group {
            if let error = controller.errorMessage {
                ContentUnavailableView {
                    Label("History can't be unlocked", systemImage: "lock.trianglebadge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Reset History", role: .destructive) { Task { await resetHistory() } }
                }
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        List(entries, selection: $selectedID) { entry in
                            HistoryEntryRow(entry: entry)
                                .tag(entry.id)
                                .contextMenu {
                                    Button("Delete", role: .destructive) { Task { await delete(entry.id) } }
                                }
                        }
                        .searchable(text: $query, prompt: "Search History")

                        HStack {
                            Text(ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear History…", role: .destructive) { showingClearConfirmation = true }
                                .disabled(entries.isEmpty)
                        }
                        .font(.caption)
                        .padding(10)
                    }
                    .frame(minWidth: 290, idealWidth: 330)

                    HistoryEntryDetail(entry: selectedEntry) {
                        if let selectedID { Task { await delete(selectedID) } }
                    }
                    .frame(minWidth: 360)
                }
            }
        }
        .task(id: "\(query)|\(controller.revision)") { await load() }
        .onChange(of: selectedID) { _, id in Task { await loadDetail(id) } }
        .confirmationDialog("Clear all History?", isPresented: $showingClearConfirmation) {
            Button("Clear History", role: .destructive) { Task { await clear() } }
        } message: {
            Text("This permanently removes every Dictation, AI Action, and stored context image.")
        }
    }

    private func load() async {
        do {
            let store = try await controller.requireStore()
            entries = try await store.entries(search: query)
            storageBytes = await store.storageBytes()
            if selectedID == nil { selectedID = entries.first?.id }
            if let selectedID { await loadDetail(selectedID) }
        } catch { }
    }

    private func loadDetail(_ id: UUID?) async {
        guard let id, let store = try? await controller.requireStore() else {
            selectedEntry = nil
            return
        }
        selectedEntry = try? await store.entry(id: id)
    }

    private func delete(_ id: UUID) async {
        guard let store = try? await controller.requireStore() else { return }
        try? await store.deleteEntry(id: id)
        if selectedID == id { selectedID = nil; selectedEntry = nil }
        controller.changed()
    }

    private func clear() async {
        guard let store = try? await controller.requireStore() else { return }
        try? await store.clear()
        selectedID = nil
        selectedEntry = nil
        controller.changed()
    }

    private func resetHistory() async {
        try? await controller.reset()
    }
}

private struct HistoryEntryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(entry.kind == .dictation ? "Dictation" : "AI Action", systemImage: entry.kind == .dictation ? "mic" : "sparkles")
                    .font(.headline)
                Spacer()
                Text(entry.createdAt, style: .relative).foregroundStyle(.secondary)
            }
            Text(entry.resultText ?? entry.instructionText ?? entry.errorText ?? entry.outcome.rawValue.capitalized)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            HStack {
                Text(entry.outcome.rawValue.capitalized)
                if let app = entry.sourceAppName { Text("· \(app)") }
            }
            .font(.caption)
            .foregroundStyle(outcomeColor)
        }
        .padding(.vertical, 4)
    }

    private var outcomeColor: Color {
        switch entry.outcome {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .running: return .orange
        }
    }
}

private struct HistoryEntryDetail: View {
    let entry: HistoryEntry?
    let delete: () -> Void

    var body: some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(entry.kind == .dictation ? "Dictation" : "AI Action").font(.title2.bold())
                        Spacer()
                        Button("Delete", role: .destructive, action: delete)
                    }
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                        .foregroundStyle(.secondary)
                    if let app = entry.sourceAppName { detailSection("Source application", app) }
                    if let instruction = entry.instructionText { detailSection("Instruction", instruction) }
                    ForEach(entry.contextInputs) { input in
                        switch input.content {
                        case .text(let text):
                            detailSection(input.source == .selection ? "Selected text" : "Clipboard text", text)
                        case .image(let image):
                            VStack(alignment: .leading, spacing: 6) {
                                Text(input.source == .selection ? "Selected image" : "Clipboard image").font(.headline)
                                if let nsImage = NSImage(data: image.data) {
                                    Image(nsImage: nsImage).resizable().scaledToFit().frame(maxHeight: 320)
                                }
                            }
                        }
                    }
                    if let result = entry.resultText, result != entry.instructionText { detailSection("Result", result) }
                    if let error = entry.errorText { detailSection(entry.outcome == .cancelled ? "Cancellation" : "Failure", error) }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a History entry", systemImage: "clock.arrow.circlepath")
        }
    }

    private func detailSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).textSelection(.enabled)
        }
    }
}
