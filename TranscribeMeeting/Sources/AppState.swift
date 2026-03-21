import AppKit
import Foundation

enum AppStatus: Equatable {
    case starting
    case ready
    case recording
    case processing
    case error(String)
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .starting
    @Published var isRecording = false
    @Published var lastMeetingPath: String? = nil

    let server = PythonServer()
    let recorder = AudioRecorder()
    let client = TranscribeClient()
    var whisperModel: String = "mlx-community/whisper-large-v3-turbo"

    private var recordingStartedAt: Date?

    init() {
        Task {
            await startServer()
        }
    }

    var isReady: Bool {
        status == .ready
    }

    var statusLabel: String {
        switch status {
        case .starting:        return "Starting server..."
        case .ready:           return "Ready"
        case .recording:       return "Recording..."
        case .processing:      return "Processing..."
        case .error(let msg):  return "Error: \(msg)"
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        do {
            try await recorder.startRecording()
            isRecording = true
            status = .recording
            recordingStartedAt = Date()
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func stopRecording() async {
        let startedAt = recordingStartedAt ?? Date()
        isRecording = false
        status = .processing

        do {
            let wavURL = try await recorder.stopRecording()
            print("WAV saved: \(wavURL.path)")

            status = .processing
            let transcript = try await client.transcribe(wavURL: wavURL, model: whisperModel)
            print("Transcript ready (\(transcript.count) chars)")

            // Save transcript as markdown in meetings/ folder alongside the WAV
            let mdURL = wavURL.deletingPathExtension().appendingPathExtension("md")
            let duration = Int(Date().timeIntervalSince(startedAt) / 60)
            let md = """
            # Meeting — \(formattedDate(startedAt))
            **Duration:** ~\(max(1, duration)) min
            **Model:** \(whisperModel)

            ## Transcript

            \(transcript)
            """
            try md.write(to: mdURL, atomically: true, encoding: .utf8)
            print("Transcript saved: \(mdURL.path)")

            lastMeetingPath = mdURL.path
            status = .ready

            // Open the meetings folder in Finder for easy access
            NSWorkspace.shared.selectFile(mdURL.path, inFileViewerRootedAtPath: "")

        } catch {
            isRecording = false
            status = .error(error.localizedDescription)
            print("Recording error: \(error.localizedDescription)")
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - Server startup

    private func startServer() async {
        do {
            try await server.start()
            try await server.waitUntilHealthy()
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }
}
