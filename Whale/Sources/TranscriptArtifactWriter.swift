import Foundation

/// Writes a completed transcription as the app's markdown meeting artifact.
///
/// The caller supplies the completed document facts and destination folder. The
/// writer owns the filename convention, markdown schema, date presentation, and
/// UTF-8 file write so those details do not leak into application orchestration.
struct TranscriptArtifactWriter {
    struct Document: Sendable {
        let startedAt: Date
        let durationMinutes: Int
        let model: BuiltInModelDescriptor
        let transcript: String
        let cleanupSummary: String
    }

    func write(_ document: Document, to folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(filename(for: document.startedAt))
        try markdown(for: document).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func filename(for date: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .replacingOccurrences(of: "Z", with: "")
        return "transcript-\(stamp).md"
    }

    private func markdown(for document: Document) -> String {
        let formattedDate = DateFormatter.localizedString(
            from: document.startedAt,
            dateStyle: .medium,
            timeStyle: .short
        )
        let sections: [String] = [
            "# Meeting — \(formattedDate)",
            "**Duration:** ~\(max(1, document.durationMinutes)) min  |  **Model:** \(document.model.markdownLabel)",
            "**Cleanup:** \(document.cleanupSummary)",
            "",
            "## Transcript",
            "",
            document.transcript,
        ]
        return sections.joined(separator: "\n")
    }
}
