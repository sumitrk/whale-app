import AppKit
import SwiftUI

struct HistoryView: View {
    private static let pageSize = 50

    @ObservedObject private var controller = HistoryController.shared
    @State private var query = ""
    @State private var entries: [HistoryEntry] = []
    @State private var stats = DictationStats()
    @State private var expandedIDs: Set<UUID> = []
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
                // then one column of rounded cards — the totals, then every entry, newest first.
                VStack(alignment: .leading, spacing: 20) {
                    HistoryHeader(
                        query: $query,
                        canClear: !entries.isEmpty,
                        onClear: { showingClearConfirmation = true }
                    )
                    .padding(.horizontal, 32)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)

                    if hasLoaded && entries.isEmpty {
                        ContentUnavailableView {
                            Label(query.isEmpty ? "No history" : "No matching history", systemImage: "clock.arrow.circlepath")
                        } description: {
                            Text(query.isEmpty ? "Dictations and AI actions will appear here." : "Try a different search.")
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        entryList
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            }
        }
        .task(id: "\(query)|\(controller.revision)") { await load() }
        .onAppear { relativeTimeReference = Date() }
        .confirmationDialog("Clear all history?", isPresented: $showingClearConfirmation) {
            Button("Clear history", role: .destructive) { Task { await clear() } }
        } message: {
            Text("This permanently removes every dictation, AI action, and stored context image.")
        }
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if query.isEmpty, stats.dictationCount > 0 {
                    HistoryStatsRow(stats: stats)
                        .padding(.bottom, 12)
                }
                ForEach(entries) { entry in
                    HistoryEntryCard(
                        entry: entry,
                        isExpanded: expandedIDs.contains(entry.id),
                        relativeTo: relativeTimeReference,
                        onToggleExpanded: { toggleExpanded(entry.id) },
                        onDelete: { Task { await delete(entry.id) } }
                    )
                    .onAppear {
                        if entry.id == entries.last?.id { Task { await loadMore() } }
                    }
                }
                if isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private func toggleExpanded(_ id: UUID) {
        withAnimation(.snappy) {
            if expandedIDs.contains(id) {
                expandedIDs.remove(id)
            } else {
                expandedIDs.insert(id)
            }
        }
    }

    private func load() async {
        let requestedQuery = query
        let requestedRevision = controller.revision

        do {
            let store = try await controller.requireStore()
            let page = try await store.entries(search: requestedQuery, limit: max(Self.pageSize, entries.count))
            let totals = try await store.dictationStats()
            guard !Task.isCancelled, requestedQuery == query, requestedRevision == controller.revision else { return }
            entries = page
            stats = totals
            hasMoreEntries = page.count >= Self.pageSize
            expandedIDs.formIntersection(page.map(\.id))
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

    private func delete(_ id: UUID) async {
        guard let store = try? await controller.requireStore() else { return }
        try? await store.deleteEntry(id: id)
        expandedIDs.remove(id)
        controller.changed()
    }

    private func clear() async {
        guard let store = try? await controller.requireStore() else { return }
        try? await store.clear()
        expandedIDs = []
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
                .frame(maxWidth: 220)

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

/// How fast the user speaks and what that saves them, over every dictation.
private struct HistoryStatsRow: View {
    let stats: DictationStats

    var body: some View {
        HStack(spacing: 8) {
            HistoryStatTile(
                value: stats.wordsPerMinute.map { $0.formatted() } ?? "–",
                label: "words per minute"
            )
            HistoryStatTile(value: Self.duration(stats.secondsSaved), label: "saved vs. typing")
            HistoryStatTile(value: stats.words.formatted(), label: "words dictated")
        }
    }

    /// "3.4h", "12m", "40s": short enough to read at a glance in a tile.
    private static func duration(_ seconds: Double) -> String {
        if seconds >= 3600 {
            return (seconds / 3600).formatted(.number.precision(.fractionLength(0...1))) + "h"
        }
        if seconds >= 60 {
            return Int((seconds / 60).rounded()).formatted() + "m"
        }
        return Int(seconds.rounded()).formatted() + "s"
    }
}

private struct HistoryStatTile: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.separator.opacity(0.5))
        }
        .accessibilityElement(children: .combine)
    }
}

/// One entry: where it was said and when, and what was said, three lines of it until opened.
private struct HistoryEntryCard: View {
    let entry: HistoryEntry
    let isExpanded: Bool
    let relativeTo: Date
    let onToggleExpanded: () -> Void
    let onDelete: () -> Void

    /// The entry with its context, loaded when an AI action is opened.
    @State private var detail: HistoryEntry?
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SourceAppIconView(name: entry.sourceAppName, bundleID: entry.sourceAppBundleID)
                Text(entry.listTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !copyText.isEmpty {
                    Button(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc", action: copy)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .help("Copy")
                }
            }

            if entry.kind == .aiAction, isExpanded {
                AIActionEntryDetail(entry: detail ?? entry)
            } else if !entry.listPreview.isEmpty {
                ExpandableText(text: entry.listPreview, isExpanded: isExpanded, onToggle: onToggleExpanded)
            }

            if entry.kind == .aiAction {
                Button(isExpanded ? "Show less" : "Show more", action: onToggleExpanded)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
        }
        .opacity(entry.isDimmedInList ? 0.6 : 1)
        .contextMenu {
            Button("Copy", action: copy).disabled(copyText.isEmpty)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .task(id: isExpanded) {
            guard isExpanded, entry.kind == .aiAction, detail == nil else { return }
            guard let store = try? await HistoryController.shared.requireStore() else { return }
            detail = try? await store.entry(id: entry.id)
        }
    }

    private var subtitle: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let time = formatter.localizedString(for: entry.createdAt, relativeTo: relativeTo)
        return entry.kind == .aiAction ? "AI action · \(time)" : time
    }

    private var copyText: String {
        (entry.resultText ?? entry.instructionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        withAnimation { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { didCopy = false }
        }
    }
}

/// Text cut to three lines, with "Show more" under it only when there is more to show.
private struct ExpandableText: View {
    private static let collapsedLines = 3
    // 1.35em leading for the body font.
    private static let lineSpacing = NSFont.preferredFont(forTextStyle: .body).pointSize * 0.35

    let text: String
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .lineSpacing(Self.lineSpacing)
                .lineLimit(isExpanded ? nil : Self.collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .background {
                    // Measured only while collapsed: whether the whole text fits the three lines.
                    if !isExpanded {
                        ViewThatFits(in: .vertical) {
                            Text(text)
                                .lineSpacing(Self.lineSpacing)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .onAppear { isTruncated = false }
                            Color.clear
                                .onAppear { isTruncated = true }
                        }
                    }
                }

            if isTruncated {
                Button(isExpanded ? "Show less" : "Show more", action: onToggle)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }
}

/// An opened AI action: the instruction, the context it was given, and what came back.
private struct AIActionEntryDetail: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let instruction = entry.instructionText {
                section("Instruction", instruction)
            }
            ForEach(entry.contextInputs) { input in
                switch input.content {
                case .text(let text):
                    section(input.source == .selection ? "Selected text" : "Clipboard text", text)
                case .image(let image):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(input.source == .selection ? "Selected image" : "Clipboard image")
                            .font(.headline)
                        if let nsImage = NSImage(data: image.data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 240)
                                .clipShape(.rect(cornerRadius: 8))
                        }
                    }
                }
            }
            if let result = entry.resultText, result != entry.instructionText {
                section("Output", result)
            }
            if let error = entry.errorText {
                section(entry.outcome == .cancelled ? "Cancellation" : "Failure", error)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct SourceAppIconView: View {
    let name: String?
    let bundleID: String?
    var size: CGFloat = 18

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
        .accessibilityHidden(true)
    }
}
