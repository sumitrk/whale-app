import Combine
import Foundation

struct PiImage: Sendable, Equatable {
    let data: Data
    let mediaType: String
}

struct JSONLFramer {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        return lines
    }
}

enum PiRuntimeStatus: Equatable {
    case stopped
    case starting
    case ready(startupMilliseconds: Int)
    case unavailable(String)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .ready: return "Ready"
        case .unavailable(let message): return message
        }
    }
}

enum PiRuntimeError: LocalizedError {
    case missingAPIKey
    case runtimeMissing
    case notReady(String)
    case malformedResponse
    case commandFailed(String)
    case emptyResult
    case processExited

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an OpenRouter API key in Settings > AI Actions"
        case .runtimeMissing: return "The bundled AI engine is missing"
        case .notReady(let reason): return reason
        case .malformedResponse: return "The AI engine returned an invalid response"
        case .commandFailed(let reason): return reason
        case .emptyResult: return "The AI Action returned no text"
        case .processExited: return "The AI engine stopped unexpectedly"
        }
    }
}

@MainActor
final class PiRuntime: ObservableObject {
    static let model = "openai/gpt-5.6-luna"
    static var actionSetupCommands: [[String: Any]] {
        [
            ["type": "new_session"],
            ["type": "set_thinking_level", "level": "off"],
            ["type": "set_auto_retry", "enabled": false],
        ]
    }

    @Published private(set) var status: PiRuntimeStatus = .stopped

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var framer = JSONLFramer()
    private var commandContinuations: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var promptContinuation: CheckedContinuation<String, Error>?
    private var activeRunID: UUID?
    private var streamedText = ""
    private var promptError: String?
    private var startTask: Task<Void, Never>?

    var hasAPIKey: Bool {
        (try? KeychainStore.string(for: .openRouterAPIKey))?.isEmpty == false
    }

    func startInBackground() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.start()
            } catch {
                if !Task.isCancelled {
                    self.status = .unavailable(error.localizedDescription)
                }
            }
            self.startTask = nil
        }
    }

    func restart() async throws {
        stop()
        try await start()
    }

    func ensureReady() async throws {
        if case .ready = status, process?.isRunning == true { return }
        if let startTask {
            await startTask.value
            if case .ready = status, process?.isRunning == true { return }
            throw PiRuntimeError.notReady(status.label)
        }
        try await start()
    }

    func perform(runID: UUID, request: AIActionRequest) async throws -> String {
        try await ensureReady()
        guard activeRunID == nil else {
            throw PiRuntimeError.notReady("Another AI Action is still stopping")
        }

        for command in Self.actionSetupCommands {
            _ = try await sendCommand(command)
        }

        activeRunID = runID
        streamedText = ""
        promptError = nil
        var command: [String: Any] = [
            "type": "prompt",
            "message": request.prompt,
        ]
        if !request.images.isEmpty {
            command["images"] = request.images.map {
                ["type": "image", "data": $0.data.base64EncodedString(), "mimeType": $0.mediaType]
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            promptContinuation = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.sendCommand(command)
                } catch {
                    self.finishPrompt(.failure(error))
                }
            }
        }
    }

    func abort(runID: UUID) async {
        guard activeRunID == runID else { return }
        finishPrompt(.failure(CancellationError()))
        _ = try? await sendCommand(["type": "abort"])
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        if process?.isRunning == true { process?.terminate() }
        input?.closeFile()
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        failPending(PiRuntimeError.processExited)
        status = .stopped
    }

    private func start() async throws {
        if case .ready = status, process?.isRunning == true { return }
        if case .starting = status {
            throw PiRuntimeError.notReady("The AI engine is still starting")
        }
        guard let apiKey = try KeychainStore.string(for: .openRouterAPIKey), !apiKey.isEmpty else {
            throw PiRuntimeError.missingAPIKey
        }
        guard !SettingsStore.shared.openRouterKeyRejected else {
            throw PiRuntimeError.notReady("Replace the rejected OpenRouter API key in Settings > AI Actions")
        }
        guard let executable = Bundle.main.resourceURL?
            .appendingPathComponent("Pi/pi/pi"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw PiRuntimeError.runtimeMissing
        }

        status = .starting
        let startedAt = ContinuousClock.now
        let runtimeDirectory = try makeRuntimeDirectory()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let child = Process()
        child.executableURL = executable
        child.arguments = [
            "--mode", "rpc", "--no-session",
            "--provider", "openrouter", "--model", Self.model, "--thinking", "off",
            "--no-tools", "--no-extensions", "--no-skills", "--no-prompt-templates",
            "--no-context-files", "--no-themes",
        ]
        child.currentDirectoryURL = runtimeDirectory
        child.environment = [
            "OPENROUTER_API_KEY": apiKey,
            "PI_CODING_AGENT_DIR": runtimeDirectory.path,
            "PI_CODING_AGENT_SESSION_DIR": runtimeDirectory.appendingPathComponent("sessions").path,
            "PI_TELEMETRY": "0",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = errorPipe

        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
        framer = JSONLFramer()
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        errorOutput?.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DiagnosticLog.log("[Pi] stderr emitted \(data.count) redacted bytes.")
        }
        child.terminationHandler = { [weak self, weak child] _ in
            Task { @MainActor [weak self, weak child] in
                guard let self, let child, self.process === child else { return }
                self.process = nil
                self.failPending(PiRuntimeError.processExited)
                self.status = .unavailable(PiRuntimeError.processExited.localizedDescription)
            }
        }

        do {
            try child.run()
            process = child
            let state = try await sendCommand(["type": "get_state"])
            guard state["success"] as? Bool == true else { throw PiRuntimeError.malformedResponse }
            _ = try await sendCommand(["type": "set_auto_retry", "enabled": false])
            let elapsedComponents = startedAt.duration(to: .now).components
            let elapsed = Int(elapsedComponents.seconds * 1_000 + elapsedComponents.attoseconds / 1_000_000_000_000_000)
            status = .ready(startupMilliseconds: elapsed)
            DiagnosticLog.log("[Pi] Ready in \(elapsed)ms using bundled runtime 0.72.1.")
        } catch {
            if child.isRunning { child.terminate() }
            output?.readabilityHandler = nil
            errorOutput?.readabilityHandler = nil
            input?.closeFile()
            output?.closeFile()
            errorOutput?.closeFile()
            input = nil
            output = nil
            errorOutput = nil
            process = nil
            status = .unavailable(error.localizedDescription)
            throw error
        }
    }

    private func sendCommand(_ payload: [String: Any]) async throws -> [String: Any] {
        guard process?.isRunning == true, let input else { throw PiRuntimeError.processExited }
        let id = UUID().uuidString
        var payload = payload
        payload["id"] = id
        let data = try JSONSerialization.data(withJSONObject: payload) + Data([0x0A])

        return try await withCheckedThrowingContinuation { continuation in
            commandContinuations[id] = continuation
            do {
                try input.write(contentsOf: data)
            } catch {
                commandContinuations.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func consume(_ data: Data) {
        for line in framer.append(data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String else {
                failPending(PiRuntimeError.malformedResponse)
                continue
            }

            if type == "response", let id = object["id"] as? String,
               let continuation = commandContinuations.removeValue(forKey: id) {
                if object["success"] as? Bool == true {
                    continuation.resume(returning: object)
                } else {
                    let message = object["error"] as? String ?? "The AI engine rejected the command"
                    continuation.resume(throwing: PiRuntimeError.commandFailed(message))
                }
                continue
            }

            guard activeRunID != nil else { continue }
            if type == "message_update", let event = object["assistantMessageEvent"] as? [String: Any] {
                switch event["type"] as? String {
                case "text_delta":
                    streamedText += event["delta"] as? String ?? ""
                case "error":
                    let providerError = event["error"] as? [String: Any]
                    promptError = providerError?["errorMessage"] as? String
                        ?? event["error"] as? String
                        ?? event["reason"] as? String
                        ?? "The provider request failed"
                default:
                    break
                }
            } else if type == "agent_end" {
                if promptError == nil,
                   let messages = object["messages"] as? [[String: Any]],
                   let assistant = messages.last(where: { $0["role"] as? String == "assistant" }),
                   assistant["stopReason"] as? String == "error" {
                    promptError = assistant["errorMessage"] as? String ?? "The provider request failed"
                }
                if let promptError {
                    finishPrompt(.failure(PiRuntimeError.commandFailed(promptError)))
                } else {
                    let text = streamedText.trimmingCharacters(in: .whitespacesAndNewlines)
                    finishPrompt(text.isEmpty ? .failure(PiRuntimeError.emptyResult) : .success(text))
                }
            }
        }
    }

    private func finishPrompt(_ result: Result<String, Error>) {
        guard let continuation = promptContinuation else { return }
        promptContinuation = nil
        activeRunID = nil
        streamedText = ""
        promptError = nil
        continuation.resume(with: result)
    }

    private func failPending(_ error: Error) {
        let commands = commandContinuations.values
        commandContinuations.removeAll()
        commands.forEach { $0.resume(throwing: error) }
        if promptContinuation != nil { finishPrompt(.failure(error)) }
    }

    private func makeRuntimeDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Whale/PiRuntime", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings: [String: Any] = [
            "retry": [
                "enabled": false,
                "maxRetries": 0,
                "provider": ["timeoutMs": 30_000, "maxRetries": 0],
            ],
            "enableInstallTelemetry": false,
        ]
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
        return directory
    }
}
