import Foundation

class PythonServer {
    private var process: Process?
    private let healthURL = URL(string: "http://127.0.0.1:8765/health")!
    private let logPath = "/tmp/transcribemeeting-server.log"

    // MARK: - Start

    func start() async throws {
        // If a server is already healthy (e.g. leftover from a previous run), just use it
        if await isHealthy() {
            print("PythonServer: server already running on :8765, reusing it")
            return
        }

        guard let serverScript = findServerScript() else {
            throw ServerError.serverScriptNotFound
        }

        let python = findPython()

        print("PythonServer: using python → \(python)")
        print("PythonServer: using script → \(serverScript)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [serverScript]

        // Working directory = server/ so relative imports (transcriber, llm) work
        proc.currentDirectoryURL = URL(fileURLWithPath: serverScript)
            .deletingLastPathComponent()

        // Log to file instead of /dev/null so we can debug startup errors
        // tail -f /tmp/transcribemeeting-server.log
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: logPath)
        proc.standardOutput = logHandle
        proc.standardError = logHandle

        try proc.run()
        self.process = proc
        print("PythonServer: started PID \(proc.processIdentifier)")
        print("PythonServer: server logs → \(logPath)")
    }

    // MARK: - Health polling

    func waitUntilHealthy(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await isHealthy() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        // Read last few lines of log to surface the error
        let log = (try? String(contentsOfFile: logPath)) ?? "(no log)"
        let tail = log.components(separatedBy: "\n").suffix(10).joined(separator: "\n")
        throw ServerError.startupTimeout(tail)
    }

    func isHealthy() async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(from: healthURL)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Stop

    func stop() {
        process?.terminate()
        process = nil
        print("PythonServer: stopped")
    }

    // MARK: - Path resolution

    private func findServerScript() -> String? {
        // 1. Bundled inside .app (production)
        if let bundled = Bundle.main.path(forResource: "server", ofType: "py",
                                          inDirectory: "scripts") {
            return bundled
        }

        // 2. Hardcoded dev path (fastest and most reliable during development)
        let devPath = "/Users/sumitkumar/Downloads/Projects/transcribe-meetings/server/server.py"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        // 3. Walk up from DerivedData binary location
        let binaryURL = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
        let derived = binaryURL
            .deletingLastPathComponent() // MacOS/
            .deletingLastPathComponent() // Contents/
            .deletingLastPathComponent() // TranscribeMeeting.app/
            .deletingLastPathComponent() // Debug/
            .deletingLastPathComponent() // Products/
            .deletingLastPathComponent() // Build/
            .deletingLastPathComponent() // DerivedData/<name>/
            .deletingLastPathComponent() // DerivedData/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("server/server.py")
            .path

        if FileManager.default.fileExists(atPath: derived) {
            return derived
        }

        return nil
    }

    private func findPython() -> String {
        let venvPython = "/Users/sumitkumar/Downloads/Projects/transcribe-meetings/.venv/bin/python3"
        if FileManager.default.fileExists(atPath: venvPython) {
            return venvPython
        }
        return "/opt/homebrew/bin/python3"
    }
}

// MARK: - Errors

enum ServerError: LocalizedError {
    case serverScriptNotFound
    case startupTimeout(String)

    var errorDescription: String? {
        switch self {
        case .serverScriptNotFound:
            return "Could not find server/server.py"
        case .startupTimeout(let log):
            return "Python server failed to start.\nLast log:\n\(log)"
        }
    }
}
