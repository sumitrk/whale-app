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
}
