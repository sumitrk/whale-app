import FluidAudio
import Foundation

/// What a capture is for. The capture lifecycle is the same for all three; the intent decides
/// what audio is recorded and what happens to the text afterwards.
enum CaptureIntent: Equatable, Sendable {
    /// Push-to-Talk: the text goes into the Insertion Target.
    case dictation
    /// Meeting audio plus the microphone, saved as a Transcript.
    case transcriptMode
    /// A spoken instruction run over a Context Snapshot.
    case aiAction

    /// Transcripts are files, not History Entries.
    var historyKind: HistoryKind? {
        switch self {
        case .dictation: .dictation
        case .aiAction: .aiAction
        case .transcriptMode: nil
        }
    }

    var capturesSystemAudio: Bool { self == .transcriptMode }

    var audioSource: AudioSource { capturesSystemAudio ? .system : .microphone }

    /// Microphone-only captures wait for the first usable buffer before they count as
    /// recording, so the start sound means "speak now". Transcript Mode records from the start.
    var waitsForMicrophone: Bool { self != .transcriptMode }

    /// Escape abandons a short capture; it must never throw away a meeting.
    var cancelsOnEscape: Bool { self != .transcriptMode }

    var diagnosticName: String {
        switch self {
        case .dictation: "dictation"
        case .transcriptMode: "transcriptMode"
        case .aiAction: "aiAction"
        }
    }
}
