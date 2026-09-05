import AppKit
import SwiftUI

enum HistoryLayoutMetrics {
    // Previous share was 0.38. The list was too narrow, so it is 1.4× that width.
    static let listFraction: CGFloat = 0.38 * 1.4
}

struct HistoryView: View {
    @ObservedObject private var controller = HistoryController.shared
    @State private var query = ""
    @State private var entries: [HistoryEntry] = []
    @State private var selectedID: UUID?
    @State private var selectedEntry: HistoryEntry?
    @State private var storageBytes: Int64 = 0
    @State private var showingClearConfirmation = false
    @State private var relativeTimeReference = Date()
    @State private var hasLoaded = false

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
                GeometryReader { geometry in
                    let listWidth = geometry.size.width * HistoryLayoutMetrics.listFraction
                    let detailWidth = max(0, geometry.size.width - listWidth - 1)

                    HStack(spacing: 0) {
                        historyList
                            .frame(width: listWidth, height: geometry.size.height)

                        Divider()

                        historyDetail
                            .frame(width: detailWidth, height: geometry.size.height)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(query)|\(controller.revision)") { await load() }
        .onAppear {
            relativeTimeReference = Date()
            if selectedID == nil {
                selectedID = controller.lastSelectedID
            }
            if selectedEntry == nil {
                selectedEntry = controller.lastSelectedEntry
            }
        }
        .onChange(of: selectedID) { _, id in
            controller.lastSelectedID = id
            Task { await loadDetail(id) }
        }
        .onChange(of: selectedEntry) { _, entry in
            controller.lastSelectedEntry = entry
        }
        .confirmationDialog("Clear all History?", isPresented: $showingClearConfirmation) {
            Button("Clear History", role: .destructive) { Task { await clear() } }
        } message: {
            Text("This permanently removes every Dictation, AI Action, and stored context image.")
        }
    }

    private var historyList: some View {
        VStack(spacing: 0) {
            HistorySearchField(query: $query)

            List(entries, selection: $selectedID) { entry in
                HistoryEntryRow(entry: entry, relativeTo: relativeTimeReference)
                    .tag(entry.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { Task { await delete(entry.id) } }
                    }
            }

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
    }

    @ViewBuilder
    private var historyDetail: some View {
        if let selectedEntry {
            HistoryEntryDetail(entry: selectedEntry) {
                if let selectedID { Task { await delete(selectedID) } }
            }
        } else if hasLoaded && entries.isEmpty {
            ContentUnavailableView {
                Label(query.isEmpty ? "No History" : "No matching History", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(query.isEmpty ? "Dictations and AI Actions will appear here." : "Try a different search.")
            }
        } else {
            Color.clear
        }
    }

    private func load() async {
        do {
            let store = try await controller.requireStore()
            entries = try await store.entries(search: query)
            storageBytes = await store.storageBytes()
            let preservedID = selectedID ?? controller.lastSelectedID
            if let preservedID, entries.contains(where: { $0.id == preservedID }) {
                selectedID = preservedID
            } else {
                selectedID = entries.first?.id
            }
            controller.lastSelectedID = selectedID
            if let selectedID, let match = entries.first(where: { $0.id == selectedID }) {
                if selectedEntry?.id != selectedID {
                    selectedEntry = match
                }
                await loadDetail(selectedID)
            } else {
                selectedEntry = nil
            }
            hasLoaded = true
        } catch {
            hasLoaded = true
        }
    }

    private func loadDetail(_ id: UUID?) async {
        guard let id else {
            selectedEntry = nil
            return
        }
        if selectedEntry?.id != id, let match = entries.first(where: { $0.id == id }) {
            selectedEntry = match
        }
        guard let store = try? await controller.requireStore() else { return }
        if let full = try? await store.entry(id: id), selectedID == id {
            selectedEntry = full
        }
    }

    private func delete(_ id: UUID) async {
        guard let store = try? await controller.requireStore() else { return }
        try? await store.deleteEntry(id: id)
        if selectedID == id {
            selectedID = nil
            selectedEntry = nil
            controller.lastSelectedID = nil
            controller.lastSelectedEntry = nil
        }
        controller.changed()
    }

    private func clear() async {
        guard let store = try? await controller.requireStore() else { return }
        try? await store.clear()
        selectedID = nil
        selectedEntry = nil
        controller.lastSelectedID = nil
        controller.lastSelectedEntry = nil
        controller.changed()
    }

    private func resetHistory() async {
        try? await controller.reset()
    }
}

private struct HistorySearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search History", text: $query)
                .textFieldStyle(.plain)

            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    query = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct HistoryEntryRow: View {
    let entry: HistoryEntry
    let relativeTo: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SourceAppIconView(appName: entry.sourceAppName)
                Text(entry.listTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(relativeTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.listPreview.isEmpty {
                Text(entry.listPreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .opacity(entry.isDimmedInList ? 0.55 : 1)
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.createdAt, relativeTo: relativeTo)
    }
}

private struct SourceAppIconView: View {
    let appName: String?

    var body: some View {
        Group {
            if let image = SourceAppIcon.image(forAppNamed: appName) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
    }
}

private enum SourceAppIcon {
    private static let cache = NSCache<NSString, NSImage>()
    private static var resolvedNames = Set<String>()

    static func image(forAppNamed name: String?) -> NSImage? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if resolvedNames.contains(trimmed) {
            return cache.object(forKey: trimmed as NSString)
        }
        resolvedNames.insert(trimmed)
        guard let image = resolve(trimmed) else { return nil }
        cache.setObject(image, forKey: trimmed as NSString)
        return image
    }

    private static func resolve(_ name: String) -> NSImage? {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }) {
            if let icon = running.icon {
                return icon
            }
            if let url = running.bundleURL {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }

        if let url = applicationURL(named: name) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private static func applicationURL(named name: String) -> URL? {
        var roots = FileManager.default.urls(
            for: .applicationDirectory,
            in: [.localDomainMask, .userDomainMask, .systemDomainMask]
        )
        roots.append(URL(fileURLWithPath: "/System/Applications"))
        roots.append(URL(fileURLWithPath: "/System/Applications/Utilities"))
        roots.append(URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"))

        for root in roots {
            let direct = root.appendingPathComponent("\(name).app")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in contents where item.pathExtension == "app" {
                if item.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame {
                    return item
                }
            }
            for item in contents where item.pathExtension.isEmpty {
                let nested = item.appendingPathComponent("\(name).app")
                if FileManager.default.fileExists(atPath: nested.path) {
                    return nested
                }
            }
        }
        return nil
    }
}

private struct HistoryEntryDetail: View {
    let entry: HistoryEntry
    let delete: () -> Void

    var body: some View {
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
    }

    private func detailSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
