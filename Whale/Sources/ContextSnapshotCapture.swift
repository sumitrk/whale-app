import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum ContextCaptureError: LocalizedError {
    case secureField
    case selectionUnavailable
    case eventPostingUnavailable
    case contextTooLarge

    var errorDescription: String? {
        switch self {
        case .secureField:
            return "AI Actions are unavailable in secure fields"
        case .selectionUnavailable:
            return "The current selection could not be captured"
        case .eventPostingUnavailable:
            return "Accessibility permission is required to capture this selection"
        case .contextTooLarge:
            return "The selected and copied context is too large for one AI Action"
        }
    }
}

@MainActor
enum ContextSnapshotCapture {
    static func capture() async throws -> ContextSnapshot {
        let focused = FocusedElementInspector.focusedElementContext()
        if focused?.snapshot.isSecureTextField == true {
            throw ContextCaptureError.secureField
        }

        let pasteboard = NSPasteboard.general
        let original = TextInsertionManager.PasteboardSnapshot.capture(from: pasteboard)
        let clipboardInputs = inputs(from: pasteboard, source: .clipboard)
        let sourceAppName = focused?.snapshot.appName ?? NSWorkspace.shared.frontmostApplication?.localizedName

        if let focused,
           let selectedText = FocusedElementInspector.selectedText(in: focused),
           !selectedText.isEmpty {
            return ContextSnapshot(
                capturedAt: Date(),
                sourceAppName: sourceAppName,
                inputs: [ContextInput(source: .selection, ordinal: 0, content: .text(selectedText))] + clipboardInputs
            )
        }

        let knownSelection = focused.flatMap(FocusedElementInspector.selectedTextRange(in:))?.length ?? 0 > 0
        guard CGPreflightPostEventAccess() else {
            if knownSelection { throw ContextCaptureError.eventPostingUnavailable }
            return ContextSnapshot(capturedAt: Date(), sourceAppName: sourceAppName, inputs: clipboardInputs)
        }

        let originalChangeCount = pasteboard.changeCount
        simulateCopy()
        defer { original.restore(to: pasteboard) }
        try await Task.sleep(for: .milliseconds(140))
        let didCopy = pasteboard.changeCount != originalChangeCount
        let selectionInputs = didCopy ? inputs(from: pasteboard, source: .selection) : []

        if knownSelection && selectionInputs.isEmpty {
            throw ContextCaptureError.selectionUnavailable
        }
        return ContextSnapshot(
            capturedAt: Date(),
            sourceAppName: sourceAppName,
            inputs: selectionInputs + clipboardInputs
        )
    }

    static func requestImages(from snapshot: ContextSnapshot, maxTotalBytes: Int = 20 * 1_024 * 1_024) throws -> [PiImage] {
        var result: [PiImage] = []
        var totalBytes = snapshot.inputs.reduce(0) { count, input in
            guard case .text(let text) = input.content else { return count }
            return count + text.utf8.count
        }

        for input in snapshot.inputs {
            guard case .image(let image) = input.content,
                  let optimized = optimizedImage(image) else { continue }
            totalBytes += optimized.data.count
            guard totalBytes <= maxTotalBytes else { throw ContextCaptureError.contextTooLarge }
            result.append(optimized)
        }
        guard totalBytes <= maxTotalBytes else { throw ContextCaptureError.contextTooLarge }
        return result
    }

    private static func inputs(from pasteboard: NSPasteboard, source: ContextInput.Source) -> [ContextInput] {
        var result: [ContextInput] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let text = item.string(forType: .string), !text.isEmpty {
                result.append(ContextInput(source: source, ordinal: result.count, content: .text(text)))
            }
            if let image = image(from: item) {
                result.append(ContextInput(source: source, ordinal: result.count, content: .image(image)))
            } else if let fileURLText = item.string(forType: .fileURL),
               let url = URL(string: fileURLText), url.isFileURL,
               isSupportedImageFile(url),
               let data = try? Data(contentsOf: url) {
                result.append(ContextInput(
                    source: source,
                    ordinal: result.count,
                    content: .image(ContextImage(data: data, mediaType: mediaType(for: url)))
                ))
            }
        }
        return result
    }

    private static func image(from item: NSPasteboardItem) -> ContextImage? {
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "image/png"),
            (NSPasteboard.PasteboardType("public.jpeg"), "image/jpeg"),
            (NSPasteboard.PasteboardType("public.heic"), "image/heic"),
            (NSPasteboard.PasteboardType("org.webmproject.webp"), "image/webp"),
            (.tiff, "image/tiff"),
        ]
        for (type, mediaType) in candidates {
            if let data = item.data(forType: type), !data.isEmpty {
                return ContextImage(data: data, mediaType: mediaType)
            }
        }
        return nil
    }

    private static func isSupportedImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return [UTType.png, .jpeg, .heic, .webP].contains(type)
    }

    private static func mediaType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    private static func optimizedImage(_ image: ContextImage) -> PiImage? {
        guard let source = NSImage(data: image.data) else { return nil }
        let longest = max(source.size.width, source.size.height)
        let scale = longest > 2_048 ? 2_048 / longest : 1
        let size = NSSize(width: max(1, source.size.width * scale), height: max(1, source.size.height * scale))
        let resized = NSImage(size: size)
        resized.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else { return nil }
        return PiImage(data: data, mediaType: "image/jpeg")
    }

    private static func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
