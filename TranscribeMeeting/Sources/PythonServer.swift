import Foundation

class PythonServer {
    private var process: Process?
    private let healthURL = URL(string: "http://127.0.0.1:8765/health")!
    private let logPath = "/tmp/transcribemeeting-server.log"

    // MARK: - Start

    func start() async throws {
        // Always kill any leftover process on this port so updated code always loads.
        killProcessOnPort(8765)

        let proc = Process()

        if let bundledBinary = findBundledBinary() {
            // Production: PyInstaller standalone binary bundled inside the .app
            print("PythonServer: using bundled binary → \(bundledBinary)")
            proc.executableURL = URL(fileURLWithPath: bundledBinary)
            proc.arguments = []
            proc.currentDirectoryURL = URL(fileURLWithPath: bundledBinary).deletingLastPathComponent()
        } else if let serverScript = findServerScript() {
            // Development: run server.py with the venv Python
            let python = findPython()
            print("PythonServer: using python → \(python)")
            print("PythonServer: using script → \(serverScript)")
            proc.executableURL = URL(fileURLWithPath: python)
            proc.arguments = [serverScript]
            // Working directory = server/ so relative imports (transcriber, llm) work
            proc.currentDirectoryURL = URL(fileURLWithPath: serverScript).deletingLastPathComponent()
        } else {
            throw ServerError.serverScriptNotFound
        }

        // Ensure Homebrew and system tools (ffmpeg, etc.) are on PATH.
        // macOS apps launched from Xcode get a stripped environment that excludes /opt/homebrew/bin.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "")
        proc.environment = env

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

    private func killProcessOnPort(_ port: Int) {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-t", "-i:\(port)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = Pipe()
        try? lsof.run()
        lsof.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for pidStr in output.components(separatedBy: .newlines) {
            if let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)) {
                kill(pid, SIGTERM)
                print("PythonServer: killed stale process \(pid) on :\(port)")
            }
        }
    }

    // MARK: - Path resolution

    /// Returns the path to the PyInstaller binary bundled inside the .app, if present.
    private func findBundledBinary() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let binary = resourceURL
            .appendingPathComponent("transcribe_server")
            .appendingPathComponent("transcribe_server")
            .path
        return FileManager.default.fileExists(atPath: binary) ? binary : nil
    }

    /// Returns the path to server.py for development (runs via Python interpreter).
    private func findServerScript() -> String? {
        // 1. Hardcoded dev path (fastest and most reliable during development)
        let devPath = "/Users/sumitkumar/Downloads/Projects/transcribe-meetings/server/server.py"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        // 2. Walk up from DerivedData binary location
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
            return "Could not find server binary or server/server.py"
        case .startupTimeout(let log):
            return "Python server failed to start.\nLast log:\n\(log)"
        }
    }
}
