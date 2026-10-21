import AppKit
import SwiftUI

enum HistoryLayoutMetrics {
    /// The list takes 40% of the pane; the detail view gets the remainder.
    static let listFraction: CGFloat = 0.4
}

struct HistoryView: View {
    private static let pageSize = 50

    @ObservedObject private var controller = HistoryController.shared
    @State private var query = ""
    @State private var entries: [HistoryEntry] = []
    @State private var selectedID: UUID?
    @State private var selectedEntry: HistoryEntry?
    @State private var showingClearConfirmation = false
    @State private var relativeTimeReference = Date()
    @State private var hasLoaded = false
    @State private var hasMoreEntries = false
    @State private var isLoadingMore = false

    var body: some View {
        Group {
            if let error = controller.errorMessage {
                ContentUnavailableView {
                    Label("History can't be unlocked", systemImage: "lock.trianglebadge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Reset history", role: .destructive) { Task { await resetHistory() } }
                }
            } else {
                // Laid out like the other Settings pages: the large title where theirs sits,
                // then content in rounded cards — a card per entry, and the chosen one's
                // details in a card beside them.
                VStack(alignment: .leading, spacing: 20) {
                    HistoryHeader(
                        query: $query,
                        canClear: !entries.isEmpty,
                        onClear: { showingClearConfirmation = true }
                    )

                    GeometryReader { geometry in
                        HStack(alignment: .top, spacing: 16) {
                            HistoryCardList(
                                entries: entries,
                                selectedID: $selectedID,
                                isLoadingMore: isLoadingMore,
                                relativeTo: relativeTimeReference,
                                onReachEnd: { Task { await loadMore() } },
                                onDelete: { id in Task { await delete(id) } }
                            )
                            .frame(width: geometry.size.width * HistoryLayoutMetrics.listFraction)

                            HistoryDetailCard(
                                entry: selectedEntry,
                                isEmpty: hasLoaded && entries.isEmpty,
                                isSearching: !query.isEmpty,
                                relativeTo: relativeTimeReference
                            )
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 24)
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
        .confirmationDialog("Clear all history?", isPresented: $showingClearConfirmation) {
            Button("Clear history", role: .destructive) { Task { await clear() } }
        } message: {
            Text("This permanently removes every dictation, AI action, and stored context image.")
        }
    }

    private func load() async {
        entries = []
        hasMoreEntries = false
        hasLoaded = false
        isLoadingMore = false
        let requestedQuery = query
        let requestedRevision = controller.revision

        do {
            let store = try await controller.requireStore()
            let page = try await store.entries(search: requestedQuery, limit: Self.pageSize)
            guard !Task.isCancelled, requestedQuery == query, requestedRevision == controller.revision else { return }
            entries = page
            hasMoreEntries = page.count == Self.pageSize
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
            guard !Task.isCancelled, requestedQuery == query, requestedRevision == controller.revision else { return }
            hasLoaded = true
        }
    }

    private func loadMore() async {
        guard hasMoreEntries, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        let requestedQuery = query
        let requestedRevision = controller.revision
        do {
            let store = try await controller.requireStore()
            let page = try await store.entries(
                search: requestedQuery,
                limit: Self.pageSize,
                offset: entries.count
            )
            guard !Task.isCancelled, requestedQuery == query, requestedRevision == controller.revision else { return }
            entries.append(contentsOf: page)
            hasMoreEntries = page.count == Self.pageSize
        } catch { }
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

/// The page title, with search and the page's one menu beside it. Clearing everything is
/// rare and destructive, so it sits in that menu rather than as a button on the page.
private struct HistoryHeader: View {
    @Binding var query: String
    let canClear: Bool
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("History")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 16)

            HistorySearchField(query: $query)
                .frame(maxWidth: 240)

            Menu {
                Button("Clear history…", role: .destructive, action: onClear)
                    .disabled(!canClear)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .fixedSize()
            .accessibilityLabel("More history actions")
        }
    }
}

private struct HistorySearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search history", text: $query)
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
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Color.primary.opacity(0.06), in: .capsule)
    }
}

/// One card per entry. The arrow keys move the selection, like the list they replace.
private struct HistoryCardList: View {
    let entries: [HistoryEntry]
    @Binding var selectedID: UUID?
    let isLoadingMore: Bool
    let relativeTo: Date
    let onReachEnd: () -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(entries) { entry in
                        Button { selectedID = entry.id } label: {
                            HistoryEntryCard(
                                entry: entry,
                                isSelected: entry.id == selectedID,
                                relativeTo: relativeTo
                            )
                        }
                        .buttonStyle(.plain)
                        .id(entry.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { onDelete(entry.id) }
                        }
                        .onAppear {
                            if entry.id == entries.last?.id { onReachEnd() }
                        }
                    }
                    if isLoadingMore {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(by: -1, proxy: proxy) }
            .onKeyPress(.downArrow) { move(by: 1, proxy: proxy) }
        }
    }

    private func move(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let index = entries.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = entries.first?.id
            return .handled
        }
        let next = index + offset
        guard entries.indices.contains(next) else { return .handled }
        selectedID = entries[next].id
        proxy.scrollTo(entries[next].id)
        return .handled
    }
}

private struct HistoryEntryCard: View {
    let entry: HistoryEntry
    let isSelected: Bool
    let relativeTo: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SourceAppIconView(name: entry.sourceAppName, bundleID: entry.sourceAppBundleID)
                Text(entry.listTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(relativeTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.listPreview.isEmpty {
                Text(entry.listPreview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor),
            in: .rect(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.5))
        }
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
        .opacity(entry.isDimmedInList ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.createdAt, relativeTo: relativeTo)
    }
}

/// The selected entry, in the same rounded card the Settings sections use.
private struct HistoryDetailCard: View {
    let entry: HistoryEntry?
    let isEmpty: Bool
    let isSearching: Bool
    let relativeTo: Date

    var body: some View {
        Group {
            if let entry {
                HistoryEntryDetail(entry: entry, relativeTo: relativeTo)
            } else if isEmpty {
                ContentUnavailableView {
                    Label(isSearching ? "No matching history" : "No history", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(isSearching ? "Try a different search." : "Dictations and AI actions will appear here.")
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator.opacity(0.5))
        }
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
    }
}

private struct SourceAppIconView: View {
    let name: String?
    let bundleID: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = SourceApp.icon(bundleID: bundleID, name: name) {
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
        .frame(width: size, height: size)
    }
}

private struct HistoryEntryDetail: View {
    private static let iconSize: CGFloat = 20
    private static let iconSpacing: CGFloat = 6
    // 1.35em leading for the body font.
    private static let bodyLineSpacing = NSFont.preferredFont(forTextStyle: .body).pointSize * 0.35

    let entry: HistoryEntry
    let relativeTo: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Self.iconSpacing) {
                        SourceAppIconView(
                            name: entry.sourceAppName,
                            bundleID: entry.sourceAppBundleID,
                            size: Self.iconSize
                        )
                        Text(entry.listTitle).font(.title2.bold())
                    }
                    HStack(spacing: 3) {
                        Text(entry.kind == .dictation ? "Dictation" : "AI action")
                        Text("·")
                        Text(relativeTime)
                    }
                    .foregroundStyle(.secondary)
                    // Align the subtitle with the app name, not the icon.
                    .padding(.leading, Self.iconSize + Self.iconSpacing)
                }
                if let instruction = entry.instructionText {
                    if entry.kind == .dictation {
                        detailText(instruction)
                    } else {
                        detailSection("Instruction", instruction)
                    }
                }
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
                if let result = entry.resultText, result != entry.instructionText {
                    detailSection(entry.kind == .dictation ? "Result" : "Output", result)
                }
                if let error = entry.errorText { detailSection(entry.outcome == .cancelled ? "Cancellation" : "Failure", error) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: entry.createdAt, relativeTo: relativeTo)
    }

    private func detailSection(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            detailText(text)
        }
    }

    private func detailText(_ text: String) -> some View {
        Text(text)
            .lineSpacing(Self.bodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
