import AppKit
import SwiftUI

struct ModelsSettingsView: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared

    var body: some View {
        SettingsPageLayout(title: "Models") {
            ModelListSections()
        }
        .task { await modelStore.refreshNow() }
    }
}

/// The model list itself, without a page around it, so the settings pane and the onboarding
/// step present exactly the same rows.
///
/// Two boxes rather than one: the models Whale ships and installs itself, then the
/// bring-your-own folder under its own header.
struct ModelListSections: View {
    var body: some View {
        SettingsSection {
            ForEach(BuiltInModelCatalog.models(from: .bundled)) { model in
                ModelRow(model: model)
            }
        }

        SettingsSection("Custom", footer: "All models run locally on your Mac. Audio never leaves the device.") {
            ForEach(BuiltInModelCatalog.models(from: .custom)) { model in
                ModelRow(model: model)
            }
        }
    }
}

/// One model in the list. Every row has one action in the same place — Download, Use, Retry
/// or Choose folder — and the model in use says "In use" there instead, on a tinted row, so
/// which one dictation runs on is never in doubt. Everything else that acts on the files
/// (delete, show in Finder, change folder) is in the row's "⋯" menu.
private struct ModelRow: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var pendingDelete: PendingModelDelete?

    let model: BuiltInModelDescriptor

    private var rowModel: TranscriptionModelRowModel {
        TranscriptionModelRowModel(
            model: model,
            installState: modelStore.installState(for: model.id),
            isSelected: settings.selectedBuiltInModelID == model.id
        )
    }

    private var isInUse: Bool {
        settings.selectedBuiltInModelID == model.id && rowModel.isReady
    }

    private var isPreparing: Bool {
        modelStore.preparingModelID == model.id
    }

    var body: some View {
        let row = rowModel

        HStack(alignment: .center, spacing: 12) {
            ModelIcon(model: model)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)
                    .fontWeight(.medium)

                // The load phase explains a multi-minute wait, so let it wrap onto a second
                // line rather than truncating the explanation away.
                Text(subtitle(for: row))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let errorText = row.errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if row.isBusy || isPreparing {
                    ProgressView()
                        .controlSize(.small)
                    if row.isCancellable {
                        Button("Cancel") { modelStore.cancel(model.id) }
                    }
                } else {
                    if let control = languageControl(for: row) {
                        ModelLanguageControlView(control: control) { option in
                            settings.setLanguageCode(option.decodingLanguageCode, for: model.id)
                        }
                    }
                    if isInUse {
                        Label("In use", systemImage: "checkmark.circle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    } else if row.isReady {
                        Button("Use") { modelStore.use(model.id) }
                    } else if let title = row.primaryActionTitle {
                        Button(title, action: triggerPrimaryAction)
                    }
                }

                if hasMenuItems(for: row) {
                    Menu {
                        menuItems(for: row)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 16, height: 16)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("More actions for \(model.title)")
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            // Without this the title takes the space it wants and a long language name
            // squeezes the button beside it down to a sliver.
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
        .background(isInUse ? Color.accentColor.opacity(0.07) : .clear)
        .contextMenu { menuItems(for: row) }
        .confirmationDialog(
            "Delete \(model.title)?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { _ in
            Button("Delete", role: .destructive) { modelStore.reset(model.id) }
        } message: { request in
            Text(request.message)
        }
    }

    private func subtitle(for row: TranscriptionModelRowModel) -> String {
        if isPreparing {
            return "Preparing for first use… this takes a few seconds"
        }
        return row.statusLine(capabilityLabel: model.capabilityLabel, downloadSize: model.downloadSize)
    }

    /// Only an installed model with a real choice gets a language control — including one
    /// that isn't in use, so a language can be set before switching to it. A model that knows
    /// one language says so in its subtitle instead of showing a disabled button.
    private func languageControl(for row: TranscriptionModelRowModel) -> ModelLanguageControl? {
        guard row.isReady else { return nil }

        let control = ModelLanguageResolver.control(
            for: model,
            detected: settings.detectedLanguageCapability(for: model.id),
            storedCode: settings.languageCode(for: model.id)
        )
        return control?.allowsSelection == true ? control : nil
    }

    private func hasMenuItems(for row: TranscriptionModelRowModel) -> Bool {
        let fileActions = row.isReady && (model.changeActionTitle != nil || localModelPath != nil)
        return fileActions || row.resetActionTitle != nil || model.id == .barkCleanEnglish
    }

    /// The "⋯" menu and the row's right-click menu: everything that acts on the model's files.
    @ViewBuilder
    private func menuItems(for row: TranscriptionModelRowModel) -> some View {
        // CC BY's credit, as a link to the model card, which names the authors, the licence and
        // what was changed. See Resources/Licenses/Bark-3.0-Clean before removing it.
        if model.id == .barkCleanEnglish {
            Button("About \(model.title) (CC BY 4.0)…") {
                NSWorkspace.shared.open(BarkCleanModelCatalog.modelCardURL)
            }
            Divider()
        }

        if row.isReady, let title = model.changeActionTitle {
            Button("\(title)…", action: chooseLocalFolder)
        }

        if row.isReady, let path = localModelPath {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .disabled(!FileManager.default.fileExists(atPath: path))

            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }

        if let resetActionTitle = row.resetActionTitle {
            Divider()
            if model.ownsModelFiles {
                Button("\(resetActionTitle)…", role: .destructive) { requestDelete(row) }
            } else {
                Button(resetActionTitle, role: .destructive) { modelStore.reset(model.id) }
            }
        }
    }

    /// Asks before erasing anything, naming the space it frees and, for the active model,
    /// that dictation stops working until another model is ready.
    private func requestDelete(_ row: TranscriptionModelRowModel) {
        pendingDelete = PendingModelDelete(
            byteCount: localModelPath.flatMap(Self.allocatedByteCount(at:)),
            isActive: row.status == .active
        )
    }

    private static func allocatedByteCount(at path: String) -> Int64? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        guard let files = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return nil }

        var total: Int64 = 0
        for case let file as URL in files {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total > 0 ? total : nil
    }

    private var localModelPath: String? {
        switch model.id {
        case .parakeetEnglishV2:
            return AppRuntimeInfo.current.parakeetEnglishV2DirectoryURL.path
        case .barkCleanEnglish:
            return AppRuntimeInfo.current.barkCleanDirectoryURL.path
        case .whisperLargeV3Turbo, .whisperLocalFolder:
            return settings.localModelPath(for: model.id)
        case .appleSpeech:
            return nil
        }
    }

    private func triggerPrimaryAction() {
        switch model.provisioning {
        case .download, .systemAsset:
            modelStore.install(model.id)
        case .localFolder:
            chooseLocalFolder()
        }
    }

    private func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose folder"
        panel.message = "Select a WhisperKit/Core ML folder that contains MelSpectrogram, AudioEncoder, and TextDecoder."

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        modelStore.connectLocalModel(model.id, folderURL: folderURL)
    }
}

/// What the delete confirmation needs to say.
private struct PendingModelDelete {
    let byteCount: Int64?
    let isActive: Bool

    var message: String {
        let freed = byteCount.map {
            "This frees \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)). "
        } ?? ""
        let consequence = isActive
            ? "It's the model dictation uses now, so dictation won't work until you download it again or pick another model."
            : "You can download it again from here."
        return freed + consequence
    }
}

/// The trailing language control, in both of its shapes, so their styling cannot drift apart.
///
/// Both shapes are a plain bordered `Button`, which is what makes them match the Download
/// button they stand in for. SwiftUI's own `Menu` cannot be used here: inside
/// `.formStyle(.grouped)` macOS renders it — and `NSPopUpButton` with it — in the inline
/// System Settings style, bare text beside a detached chevron badge, and no `menuStyle` or
/// `buttonStyle` overrides that. A `Button` keeps its bezel in the same context, so the
/// control is a real button that carries the chevron in its label and raises a real `NSMenu`.
/// That also buys the things a 100-item SwiftUI menu does badly: scrolling, type-ahead, and
/// checkmarks that survive the same language appearing in two groups.
private struct ModelLanguageControlView: View {
    let control: ModelLanguageControl
    let onSelect: (TranscriptionLanguageOption) -> Void

    @State private var anchor = LanguageMenuAnchor()
    @State private var controller = LanguageMenuController()

    var body: some View {
        if control.allowsSelection {
            Button {
                guard let view = anchor.view else { return }
                controller.present(control: control, from: view, onSelect: onSelect)
            } label: {
                HStack(spacing: 4) {
                    Text(control.selection.title)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .background(LanguageMenuAnchorView(anchor: anchor))
            .fixedSize()
        } else {
            // The same bezel holding the one settled answer. Disabled because there is nothing
            // to choose, and declining to hit-test so the click falls through to the row
            // underneath rather than leaving a dead patch in the middle of a clickable row.
            Button(control.selection.title) {}
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(true)
                .allowsHitTesting(false)
                .accessibilityRemoveTraits(.isButton)
                .fixedSize()
        }
    }
}

/// Somewhere to keep the AppKit view the menu hangs off, so the popup lands under the button
/// rather than under the mouse.
@MainActor
private final class LanguageMenuAnchor {
    weak var view: NSView?
}

private struct LanguageMenuAnchorView: NSViewRepresentable {
    let anchor: LanguageMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// Builds and raises the language menu. Items carry their index as a tag rather than a code,
/// because the user's own languages deliberately appear twice and only the tapped one should
/// answer.
@MainActor
private final class LanguageMenuController: NSObject {
    private var options: [TranscriptionLanguageOption] = []
    private var onSelect: ((TranscriptionLanguageOption) -> Void)?

    func present(
        control: ModelLanguageControl,
        from view: NSView,
        onSelect: @escaping (TranscriptionLanguageOption) -> Void
    ) {
        self.onSelect = onSelect

        // SwiftUI hands representables an unflipped view, so "just under the button" is below
        // `minY`, not above `maxY`. Getting this backwards opens the menu over the control it
        // belongs to, so honour the flag rather than hardcoding today's answer.
        let below = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4

        makeMenu(for: control)
            .popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: below), in: view)
    }

    /// Split from `present` so the menu it builds can be inspected without raising it.
    func makeMenu(for control: ModelLanguageControl) -> NSMenu {
        options = []

        let menu = NSMenu()
        menu.autoenablesItems = false

        for (index, group) in control.optionGroups.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }

            for option in group {
                let item = NSMenuItem(title: option.title, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.tag = options.count
                item.state = option == control.selection ? .on : .off
                options.append(option)
                menu.addItem(item)
            }
        }

        return menu
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard options.indices.contains(sender.tag) else { return }
        onSelect?(options[sender.tag])
    }
}

/// The mark is derived from where a model comes from, never assigned per model: every
/// Parakeet checkpoint is the blue waveform, every Whisper checkpoint the purple bubble,
/// and anything the user supplied themselves is the orange folder whatever loads it.
///
/// So adding a model to a family the app already speaks costs nothing here, and adding a
/// whole new engine fails to compile until someone picks its mark on purpose.
private struct ModelIcon: View {
    let model: BuiltInModelDescriptor

    private var appearance: (color: Color, symbol: String) {
        // A folder the user pointed at is identified by that fact, not by the engine that
        // happens to read it — otherwise it would be indistinguishable from bundled Whisper.
        guard model.source != .custom else {
            return (.settingsOrange, "folder.fill")
        }

        switch model.group {
        case .parakeet: return (.settingsBlue, "waveform")
        case .whisper:  return (.settingsPurple, "text.bubble.fill")
        case .apple:    return (.settingsGray, "apple.logo")
        }
    }

    var body: some View {
        SettingsIconTile(symbol: appearance.symbol, tint: appearance.color, cornerRadius: 10)
            .accessibilityHidden(true)
    }
}
