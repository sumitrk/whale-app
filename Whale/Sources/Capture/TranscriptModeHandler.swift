import AppKit
import Foundation

/// Transcript Mode saves the transcript as a markdown file and shows it in Finder.
@MainActor
final class TranscriptModeHandler: CaptureIntentHandler {
    private let writer = TranscriptArtifactWriter()
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func complete(_ transcript: CaptureTranscript, entry: CaptureEntry?) async throws -> CaptureCompletion {
        let document = TranscriptArtifactWriter.Document(
            startedAt: transcript.startedAt,
            durationMinutes: Int(Date.now.timeIntervalSince(transcript.startedAt) / 60),
            model: transcript.modelID.descriptor,
            transcript: transcript.text
        )
        let url = try writer.write(document, to: settings.transcriptFolder)
        DiagnosticLog.log("[Capture] Saved transcript to \(url.path).")
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        return .saved
    }
}
