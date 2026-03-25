import AppKit
import Foundation
import ServiceManagement

/// Central settings store backed by UserDefaults.
/// Shared singleton — read from anywhere, mutate only on the main thread.
class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    // MARK: - Shortcuts: Push-to-Talk

    /// PTT key code (default: 63 = Fn/Globe).
    @Published var pttKeyCode: Int {
        didSet { ud.set(pttKeyCode, forKey: Keys.pttKeyCode) }
    }
    /// PTT modifier flags (default: 0 — Fn has no modifiers).
    @Published var pttModifiers: Int {
        didSet { ud.set(pttModifiers, forKey: Keys.pttModifiers) }
    }
    var pttKeyLabel: String { keyLabel(keyCode: pttKeyCode, modifiers: pttModifiers) }

    // MARK: - Shortcuts: Toggle Record

    /// Toggle key code (default: 17 = T).
    @Published var toggleKeyCode: Int {
        didSet { ud.set(toggleKeyCode, forKey: Keys.toggleKeyCode) }
    }
    /// Toggle modifier flags (default: ⌘⇧).
    @Published var toggleModifiers: Int {
        didSet { ud.set(toggleModifiers, forKey: Keys.toggleModifiers) }
    }
    var toggleKeyLabel: String { keyLabel(keyCode: toggleKeyCode, modifiers: toggleModifiers) }

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

    // MARK: - Onboarding

    @Published var hasCompletedOnboarding: Bool {
        didSet { ud.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
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

    // MARK: - Init

    private let ud = UserDefaults.standard

    private static let defaultModifiers = Int(NSEvent.ModifierFlags([.command, .shift]).rawValue)

    private init() {
        transcriptFolderPath     = ud.string(forKey: Keys.transcriptFolder) ?? ""
        hasCompletedOnboarding   = ud.bool(forKey: Keys.hasCompletedOnboarding)
        launchAtLogin            = ud.bool(forKey: Keys.launchAtLogin)
        toggleKeyCode            = (ud.object(forKey: Keys.toggleKeyCode) as? Int) ?? 17
        toggleModifiers          = (ud.object(forKey: Keys.toggleModifiers) as? Int) ?? SettingsStore.defaultModifiers
        pttKeyCode               = (ud.object(forKey: Keys.pttKeyCode) as? Int) ?? 63
        pttModifiers             = (ud.object(forKey: Keys.pttModifiers) as? Int) ?? 0
    }

    // MARK: - Key name helper

    func keyLabel(keyCode: Int, modifiers: Int) -> String {
        // Solo modifier key (Fn, Right ⌘, Right ⌥, etc.)
        if modifiers == 0, let name = modifierOnlyKeyName(keyCode) { return name }
        // Regular combo
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += keyCodeName(keyCode)
        return s
    }

    private func keyCodeName(_ code: Int) -> String {
        let map: [Int: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 18:"1", 19:"2",
            20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9", 26:"7", 27:"-", 28:"8",
            29:"0", 31:"O", 32:"U", 34:"I", 35:"P", 37:"L", 38:"J", 39:"'", 40:"K",
            41:";", 42:"\\", 43:",", 44:"/", 45:"N", 46:"M", 47:".", 49:"Space",
            51:"⌫", 53:"⎋", 123:"←", 124:"→", 125:"↓", 126:"↑"
        ]
        return map[code] ?? "?"
    }

    private enum Keys {
        static let transcriptFolder      = "transcriptFolderPath"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let launchAtLogin         = "launchAtLogin"
        static let toggleKeyCode         = "toggleKeyCode"
        static let toggleModifiers       = "toggleModifiers"
        static let pttKeyCode            = "pttKeyCode"
        static let pttModifiers          = "pttModifiers"
    }
}
