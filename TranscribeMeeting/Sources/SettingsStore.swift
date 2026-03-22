import AppKit
import Foundation
import ServiceManagement

/// Central settings store backed by UserDefaults.
/// Shared singleton — read from anywhere, mutate only on the main thread.
class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    // MARK: - Shortcuts

    /// Push-to-talk is always Fn/Globe (hardware key, not rebindable).
    let pushToTalkKeyLabel = "Globe / Fn"

    /// Toggle-record key code (default: 17 = T).
    @Published var toggleKeyCode: Int {
        didSet { ud.set(toggleKeyCode, forKey: Keys.toggleKeyCode) }
    }

    /// Toggle-record modifier flags raw value (default: ⌘⇧).
    @Published var toggleModifiers: Int {
        didSet { ud.set(toggleModifiers, forKey: Keys.toggleModifiers) }
    }

    // MARK: - Toggle Record

    /// Folder where toggle-record transcripts (.md) are saved.
    @Published var transcriptFolderPath: String {
        didSet { ud.set(transcriptFolderPath, forKey: Keys.transcriptFolder) }
    }

    var transcriptFolder: URL {
        transcriptFolderPath.isEmpty
            ? AudioRecorder.meetingsFolder()
            : URL(fileURLWithPath: transcriptFolderPath)
    }

    // MARK: - Transcription model

    @Published var activeModelId: String {
        didSet { ud.set(activeModelId, forKey: Keys.activeModel) }
    }

    // MARK: - General

    @Published var launchAtLogin: Bool {
        didSet {
            ud.set(launchAtLogin, forKey: Keys.launchAtLogin)
            if launchAtLogin {
                try? SMAppService.mainApp.register()
            } else {
                try? SMAppService.mainApp.unregister()
            }
        }
    }

    // MARK: - AI Summarisation

    @Published var aiEnabled: Bool {
        didSet { ud.set(aiEnabled, forKey: Keys.aiEnabled) }
    }

    @Published var aiProvider: String {
        didSet { ud.set(aiProvider, forKey: Keys.aiProvider) }
    }

    @Published var aiApiKey: String {
        didSet { ud.set(aiApiKey, forKey: Keys.aiApiKey) }
    }

    // MARK: - Init

    private let ud = UserDefaults.standard

    private static let defaultModifiers = Int(NSEvent.ModifierFlags([.command, .shift]).rawValue)

    private init() {
        transcriptFolderPath = ud.string(forKey: Keys.transcriptFolder) ?? ""
        activeModelId        = ud.string(forKey: Keys.activeModel)      ?? "mlx-community/parakeet-tdt-0.6b-v3"
        launchAtLogin        = ud.bool(forKey: Keys.launchAtLogin)
        aiEnabled            = ud.bool(forKey: Keys.aiEnabled)
        aiProvider           = ud.string(forKey: Keys.aiProvider) ?? "anthropic"
        aiApiKey             = ud.string(forKey: Keys.aiApiKey)   ?? ""
        toggleKeyCode        = (ud.object(forKey: Keys.toggleKeyCode) as? Int) ?? 17
        toggleModifiers      = (ud.object(forKey: Keys.toggleModifiers) as? Int) ?? SettingsStore.defaultModifiers
    }

    // MARK: - Keys

    private enum Keys {
        static let transcriptFolder = "transcriptFolderPath"
        static let activeModel      = "activeModelId"
        static let launchAtLogin    = "launchAtLogin"
        static let aiEnabled        = "aiEnabled"
        static let aiProvider       = "aiProvider"
        static let aiApiKey         = "aiApiKey"
        static let toggleKeyCode    = "toggleKeyCode"
        static let toggleModifiers  = "toggleModifiers"
    }
}
