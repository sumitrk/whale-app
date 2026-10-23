import AppKit
import Foundation

enum AIActionHandlerError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut: "The AI Action timed out after 30 seconds"
        }
    }
}

/// An AI Action fixes its Context Snapshot before the microphone opens, then runs the spoken
/// instruction over it on OpenRouter (ADR-0003).
@MainActor
final class AIActionHandler: CaptureIntentHandler {
    static let timeout: Duration = .seconds(30)

    private let client: OpenRouterClient
    private let settings: SettingsStore
    private var snapshot: ContextSnapshot?
    private var runID: UUID?

    init(client: OpenRouterClient, settings: SettingsStore) {
        self.client = client
        self.settings = settings
    }

    func checkReady() throws {
        guard client.hasAPIKey else { throw AIActionError.missingAPIKey }
        guard !settings.openRouterKeyRejected else {
            throw AIActionError.notReady("Replace the rejected OpenRouter API key in Settings > AI Actions")
        }
        if FocusedElementInspector.focusedElementContext()?.snapshot.isSecureTextField == true {
            throw ContextCaptureError.secureField
        }
    }

    func willRecord(entry: CaptureEntry?) async throws {
        snapshot = nil
        let captured = try await ContextSnapshotCapture.capture()
        snapshot = captured
        if let entry {
            try await entry.history.setContext(captured, for: entry.id)
        }
    }

    func complete(_ transcript: CaptureTranscript, entry: CaptureEntry?) async throws -> CaptureCompletion {
        guard let snapshot else { throw AIActionError.notReady("The AI Action has no context") }
        let instruction = transcript.text
        if let entry {
            try await entry.history.setInstruction(instruction, for: entry.id)
        }
        let request = try AIActionPromptBuilder.build(
            instruction: instruction,
            snapshot: snapshot,
            masterPrompt: settings.aiActionMasterPrompt
        )

        let runID = UUID()
        self.runID = runID
        defer { if self.runID == runID { self.runID = nil } }

        var timedOut = false
        let timeoutTask = Task { @MainActor [client] in
            do {
                try await Task.sleep(for: Self.timeout)
                timedOut = true
                await client.abort(runID: runID)
            } catch {}
        }
        defer { timeoutTask.cancel() }

        let result: String
        do {
            result = try await client.perform(runID: runID, request: request)
        } catch is CancellationError where timedOut {
            throw AIActionHandlerError.timedOut
        } catch {
            switch OpenRouterFailure.classify(error.localizedDescription) {
            case .rejectedKey: settings.openRouterKeyRejected = true
            case .outOfCredit: settings.openRouterOutOfCredit = true
            case nil: break
            }
            throw error
        }
        // A request that went through is the only proof credit exists, and the only way out
        // of the out-of-credit state.
        settings.openRouterOutOfCredit = false
        return .deliver(result, instruction: instruction)
    }

    func cancel() async {
        guard let runID else { return }
        self.runID = nil
        await client.abort(runID: runID)
    }
}
