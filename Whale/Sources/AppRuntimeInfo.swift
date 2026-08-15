import Foundation

struct AppRuntimeInfo: Equatable, Sendable {
    static let disableSparkleEnvironmentKey = "WHALE_DISABLE_SPARKLE"
    static let resetParakeetCacheEnvironmentKey = "WHALE_RESET_PARAKEET_CACHE_ON_LAUNCH"

    let homeDirectoryURL: URL
    let appSupportDirectoryURL: URL
    let environment: [String: String]

    var isSandboxed: Bool {
        if environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            return true
        }

        return homeDirectoryURL.path.contains("/Library/Containers/")
    }

    var whaleSupportDirectoryURL: URL {
        appSupportDirectoryURL.appendingPathComponent("Whale", isDirectory: true)
    }

    var modelsDirectoryURL: URL {
        whaleSupportDirectoryURL.appendingPathComponent("Models", isDirectory: true)
    }

    var recordingsDirectoryURL: URL {
        whaleSupportDirectoryURL.appendingPathComponent("Recordings", isDirectory: true)
    }

    var transcriptsDirectoryURL: URL {
        whaleSupportDirectoryURL.appendingPathComponent("Transcripts", isDirectory: true)
    }

    var parakeetEnglishV2DirectoryURL: URL {
        modelsDirectoryURL.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true)
    }

    var sparkleDisabled: Bool {
        environment[Self.disableSparkleEnvironmentKey] == "1"
    }

    var shouldResetParakeetCacheOnLaunch: Bool {
        environment[Self.resetParakeetCacheEnvironmentKey] == "1"
    }

    var storageDescription: String {
        let mode = isSandboxed ? "sandboxed" : "unsandboxed"
        return "\(mode) appSupport=\(appSupportDirectoryURL.path)"
    }

    static var current: AppRuntimeInfo {
        let fileManager = FileManager.default
        let appSupportDirectoryURL =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        return AppRuntimeInfo(
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
            appSupportDirectoryURL: appSupportDirectoryURL,
            environment: ProcessInfo.processInfo.environment
        )
    }

    // MARK: - Sandbox → unsandboxed migration

    /// One-time migration: copies data from the old sandbox container to the
    /// standard Application Support path. Safe to call on every launch — it
    /// only acts when the container exists and the destination is empty/missing.
    static func migrateSandboxDataIfNeeded() {
        let fm = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sumitrk.transcribe-meeting"
        let containerWhale = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/Whale", isDirectory: true)

        guard fm.fileExists(atPath: containerWhale.path) else { return }

        let standardWhale = current.whaleSupportDirectoryURL

        // Only migrate if the standard location doesn't already have content.
        if fm.fileExists(atPath: standardWhale.path),
           let contents = try? fm.contentsOfDirectory(atPath: standardWhale.path),
           !contents.isEmpty {
            return
        }

        do {
            try fm.createDirectory(at: standardWhale, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(atPath: containerWhale.path)
            for item in items {
                let src = containerWhale.appendingPathComponent(item)
                let dst = standardWhale.appendingPathComponent(item)
                if !fm.fileExists(atPath: dst.path) {
                    try fm.copyItem(at: src, to: dst)
                }
            }
            DiagnosticLog.log("[Migration] Copied sandbox data from \(containerWhale.path) → \(standardWhale.path)")
        } catch {
            DiagnosticLog.log("[Migration] Failed to copy sandbox data: \(error.localizedDescription)")
        }
    }
}
