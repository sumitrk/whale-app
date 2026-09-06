import AppKit
import SwiftUI

struct ModelsSettingsView: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared

    var body: some View {
        Form {
            ModelListSections()
            SmartFormattingSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .task { await modelStore.refreshNow() }
    }
}

/// The model list itself, without a `Form` around it, so the settings pane and the
/// onboarding step present exactly the same rows.
///
/// Two boxes rather than one: the models Whale ships and installs itself, then the
/// bring-your-own folder under its own header.
struct ModelListSections: View {
    var body: some View {
        Section {
            ForEach(BuiltInModelCatalog.models(from: .bundled)) { model in
                ModelRow(model: model)
            }
        }

        Section {
            ForEach(BuiltInModelCatalog.models(from: .custom)) { model in
                ModelRow(model: model)
            }
        } header: {
            Text("Custom")
        } footer: {
            Text("All models run locally on your Mac. Audio never leaves the device.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// Post-transcription rewriting, kept out of `ModelListSections` so the onboarding
/// step stays a plain model picker.
private struct SmartFormattingSection: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Section {
            Toggle(isOn: $settings.smartFormattingEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Formatting")
                    Text("Write spoken numbers, money, dates, and times the way you would type them — “twenty one dollars and fifty cents” becomes “$21.50”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        } header: {
            Text("Formatting")
        }
    }
}

/// One model in the list. The row *is* the picker: clicking an installed row makes it the
/// active model, which is why there is no separate "Active Model" dropdown above the list.
private struct ModelRow: View {
    @ObservedObject private var modelStore = TranscriptionModelStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isHovering = false

    let model: BuiltInModelDescriptor

    private var rowModel: TranscriptionModelRowModel {
        TranscriptionModelRowModel(
            model: model,
            installState: modelStore.installState(for: model.id),
            isSelected: settings.selectedBuiltInModelID == model.id
        )
    }

    var body: some View {
        let row = rowModel

        HStack(alignment: .center, spacing: 10) {
            ModelIcon(model: model)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.title)

                HStack(spacing: 5) {
                    if row.status.showsDot {
                        Circle()
                            .fill(dotColor(for: row.status))
                            .frame(width: 7, height: 7)
                    }

                    Text(statusLine(for: row))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let errorText = row.errorText {
                    Text(errorText)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            accessory(for: row)
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering && row.isReady ? 0.06 : 0))
                .padding(.horizontal, -6)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { activate(row) }
        .contextMenu { contextMenu(for: row) }
    }

    private func statusLine(for row: TranscriptionModelRowModel) -> String {
        row.statusLine(
            capabilityLabel: model.capabilityLabel,
            hasLanguageControl: languageControl(for: row) != nil
        )
    }

    private func dotColor(for status: TranscriptionModelStatus) -> Color {
        switch status {
        case .active:                   return .green
        case .needsAttention:           return .red
        case .inactive, .notInstalled:  return .secondary.opacity(0.5)
        case .working:                  return .clear
        }
    }

    /// The language control lands where the Download button was, so the right-hand column
    /// reads the same all the way down the list. The local folder is the one row that keeps a
    /// button as well — it still has to be repointed — and that button sits to the left so the
    /// language stays in the column the eye is scanning.
    @ViewBuilder
    private func accessory(for row: TranscriptionModelRowModel) -> some View {
        if row.isBusy {
            ProgressView()
                .controlSize(.small)
        } else {
            HStack(spacing: 8) {
                if let title = row.primaryActionTitle {
                    // Deliberately not `.borderedProminent`: nothing on this pane is the one
                    // thing the user came here to do, so no row gets to claim the screen's
                    // default action.
                    Button(title) { triggerPrimaryAction() }
                        .buttonStyle(.bordered)
                }

                if let control = languageControl(for: row) {
                    ModelLanguageControlView(control: control) { option in
                        settings.setLanguageCode(option.decodingLanguageCode, for: model.id)
                    }
                }
            }
            // Without this the title takes the space it wants and a long language name
            // squeezes the button beside it down to a sliver.
            .fixedSize()
            .layoutPriority(1)
        }
    }

    /// Only an installed model gets a language control — including one that is installed but
    /// inactive, so a language can be set before switching to it rather than after.
    private func languageControl(for row: TranscriptionModelRowModel) -> ModelLanguageControl? {
        guard row.isReady else { return nil }

        return ModelLanguageResolver.control(
            for: model,
            detected: settings.detectedLanguageCapability(for: model.id),
            storedCode: settings.languageCode(for: model.id)
        )
    }

    @ViewBuilder
    private func contextMenu(for row: TranscriptionModelRowModel) -> some View {
        if let path = localModelPath {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .disabled(!FileManager.default.fileExists(atPath: path))

            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }

        if let resetActionTitle = row.resetActionTitle {
            Divider()
            Button(resetActionTitle) { modelStore.reset(model.id) }
        }
    }

    private func activate(_ row: TranscriptionModelRowModel) {
        guard row.isReady else { return }
        settings.selectedBuiltInModelID = model.id
    }

    private var localModelPath: String? {
        switch model.id {
        case .parakeetEnglishV2:
            return AppRuntimeInfo.current.parakeetEnglishV2DirectoryURL.path
        case .whisperLargeV3Turbo, .whisperLocalFolder:
            return settings.localModelPath(for: model.id)
        }
    }

    private func triggerPrimaryAction() {
        switch model.provisioning {
        case .download:
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
        panel.prompt = "Choose Folder"
        panel.message = "Select a WhisperKit/Core ML folder that contains MelSpectrogram, AudioEncoder, and TextDecoder."

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        modelStore.connectLocalModel(model.id, folderURL: folderURL)
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
            .background(LanguageMenuAnchorView(anchor: anchor))
            .fixedSize()
        } else {
            // The same bezel holding the one settled answer. Disabled because there is nothing
            // to choose, and declining to hit-test so the click falls through to the row
            // underneath rather than leaving a dead patch in the middle of a clickable row.
            Button(control.selection.title) {}
                .buttonStyle(.bordered)
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
            return (.orange, "folder.fill")
        }

        switch model.group {
        case .parakeet: return (.blue, "waveform")
        case .whisper:  return (.purple, "text.bubble.fill")
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(appearance.color)
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: appearance.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}
