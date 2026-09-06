import AppKit
import Foundation
import ServiceManagement

/// Central settings store backed by UserDefaults.
/// Shared singleton — read from anywhere, mutate only on the main thread.
@MainActor
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

    // MARK: - Shortcuts: AI Action

    /// AI Action key code (default: 59 = Left Control).
    @Published var aiActionKeyCode: Int {
        didSet { ud.set(aiActionKeyCode, forKey: Keys.aiActionKeyCode) }
    }
    @Published var aiActionModifiers: Int {
        didSet { ud.set(aiActionModifiers, forKey: Keys.aiActionModifiers) }
    }
    var aiActionKeyLabel: String { keyLabel(keyCode: aiActionKeyCode, modifiers: aiActionModifiers) }

    // MARK: - Shortcuts: Transcript Mode

    /// Toggle key code (default: 17 = T).
    @Published var toggleKeyCode: Int {
        didSet { ud.set(toggleKeyCode, forKey: Keys.toggleKeyCode) }
    }
    /// Toggle modifier flags (default: ⌘⇧).
    @Published var toggleModifiers: Int {
        didSet { ud.set(toggleModifiers, forKey: Keys.toggleModifiers) }
    }
    var toggleKeyLabel: String { keyLabel(keyCode: toggleKeyCode, modifiers: toggleModifiers) }

    // MARK: - Transcript Mode

    /// Folder where toggle-record transcripts (.md) are saved.
    @Published var transcriptFolderPath: String {
        didSet { ud.set(transcriptFolderPath, forKey: Keys.transcriptFolder) }
    }

    @Published private var transcriptFolderBookmark: String {
        didSet { ud.set(transcriptFolderBookmark, forKey: Keys.transcriptFolderBookmark) }
    }

    var transcriptFolder: URL {
        if let url = resolveTranscriptFolderURL(startAccessing: true) {
            return url
        }

        return transcriptFolderPath.isEmpty
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

    // MARK: - Transcription Models

    @Published var selectedBuiltInModelID: BuiltInModelID {
        didSet { ud.set(selectedBuiltInModelID.rawValue, forKey: Keys.selectedBuiltInModelID) }
    }

    @Published private var builtInModelLocalPaths: [String: String] {
        didSet { ud.set(builtInModelLocalPaths, forKey: Keys.builtInModelLocalPaths) }
    }

    @Published private var builtInModelLocalBookmarks: [String: String] {
        didSet { ud.set(builtInModelLocalBookmarks, forKey: Keys.builtInModelLocalBookmarks) }
    }

    /// Language per model, because the choice belongs to the model rather than to the app:
    /// Whisper can be left on German while Parakeet stays what it has always been.
    @Published private var builtInModelLanguages: [String: String] {
        didSet { ud.set(builtInModelLanguages, forKey: Keys.builtInModelLanguages) }
    }

    /// What loading each model last revealed about the languages it can decode. Only a folder
    /// the user supplied needs this; models we pin declare it in the catalog.
    @Published private var builtInModelLanguageCapabilities: [String: String] {
        didSet { ud.set(builtInModelLanguageCapabilities, forKey: Keys.builtInModelLanguageCapabilities) }
    }

    /// Rewrite spoken numbers, money, dates, and times in a transcript into
    /// their written form. On by default; the toggle exists because the rewrite
    /// also misreads some ordinary phrasing, so anyone it bites can switch it
    /// off. Read through `object(forKey:)` rather than `bool(forKey:)` so an
    /// explicit `false` is honoured instead of collapsing into the default.
    @Published var smartFormattingEnabled: Bool {
        didSet { ud.set(smartFormattingEnabled, forKey: Keys.smartFormattingEnabled) }
    }

    // MARK: - AI Actions

    static let defaultAIActionMasterPrompt = "Follow the spoken instruction using the supplied context. Preserve the user's intended tone, language, and useful formatting."

    @Published var aiActionMasterPrompt: String {
        didSet { ud.set(aiActionMasterPrompt, forKey: Keys.aiActionMasterPrompt) }
    }

    /// Set when OpenRouter answers 401 — either at verification time or in the
    /// middle of a live action. Sticky, because a rejected key stays rejected
    /// until someone replaces it or OpenRouter starts accepting it again.
    @Published var openRouterKeyRejected: Bool {
        didSet { ud.set(openRouterKeyRejected, forKey: Keys.openRouterKeyRejected) }
    }

    /// Set when OpenRouter answers 402. Deliberately does *not* block the next
    /// action: credit can be topped up outside the app, and the only proof of
    /// that is a request going through, so this clears on the next success.
    @Published var openRouterOutOfCredit: Bool {
        didSet { ud.set(openRouterOutOfCredit, forKey: Keys.openRouterOutOfCredit) }
    }

    /// The last verification that actually got an answer. Lets an offline
    /// launch keep showing the truth instead of accusing a good key.
    @Published var openRouterKeyVerified: Bool {
        didSet { ud.set(openRouterKeyVerified, forKey: Keys.openRouterKeyVerified) }
    }

    // MARK: - Init

    private let ud: UserDefaults
    private var activeTranscriptFolderURL: URL?
    private var activeSecurityScopedModelURLs: [String: URL] = [:]

    private static let defaultModifiers = Int(NSEvent.ModifierFlags([.command, .shift]).rawValue)

    init(userDefaults: UserDefaults = .standard) {
        ud = userDefaults
        transcriptFolderPath     = ud.string(forKey: Keys.transcriptFolder) ?? ""
        transcriptFolderBookmark = ud.string(forKey: Keys.transcriptFolderBookmark) ?? ""
        hasCompletedOnboarding   = ud.bool(forKey: Keys.hasCompletedOnboarding)
        launchAtLogin            = ud.bool(forKey: Keys.launchAtLogin)
        toggleKeyCode            = (ud.object(forKey: Keys.toggleKeyCode) as? Int) ?? 17
        toggleModifiers          = (ud.object(forKey: Keys.toggleModifiers) as? Int) ?? SettingsStore.defaultModifiers
        pttKeyCode               = (ud.object(forKey: Keys.pttKeyCode) as? Int) ?? 63
        pttModifiers             = (ud.object(forKey: Keys.pttModifiers) as? Int) ?? 0
        aiActionKeyCode          = (ud.object(forKey: Keys.aiActionKeyCode) as? Int) ?? 59
        aiActionModifiers        = (ud.object(forKey: Keys.aiActionModifiers) as? Int) ?? 0
        selectedBuiltInModelID   = BuiltInModelID(
            rawValue: ud.string(forKey: Keys.selectedBuiltInModelID) ?? ""
        ) ?? .parakeetEnglishV2
        builtInModelLocalPaths   = ud.dictionary(forKey: Keys.builtInModelLocalPaths) as? [String: String] ?? [:]
        builtInModelLocalBookmarks = ud.dictionary(forKey: Keys.builtInModelLocalBookmarks) as? [String: String] ?? [:]
        builtInModelLanguages    = ud.dictionary(forKey: Keys.builtInModelLanguages) as? [String: String] ?? [:]
        builtInModelLanguageCapabilities = ud.dictionary(forKey: Keys.builtInModelLanguageCapabilities) as? [String: String] ?? [:]
        smartFormattingEnabled   = (ud.object(forKey: Keys.smartFormattingEnabled) as? Bool) ?? true
        aiActionMasterPrompt     = ud.string(forKey: Keys.aiActionMasterPrompt) ?? Self.defaultAIActionMasterPrompt
        openRouterKeyRejected    = ud.bool(forKey: Keys.openRouterKeyRejected)
        openRouterOutOfCredit    = ud.bool(forKey: Keys.openRouterOutOfCredit)
        openRouterKeyVerified    = ud.bool(forKey: Keys.openRouterKeyVerified)
    }

    func setTranscriptFolderURL(_ url: URL?) {
        stopAccessingTranscriptFolder()
        transcriptFolderPath = url?.path ?? ""
        transcriptFolderBookmark = makeBookmarkString(for: url) ?? ""
    }

    func localModelPath(for modelID: BuiltInModelID) -> String? {
        if let url = resolveLocalModelURL(for: modelID, startAccessing: false) {
            return url.path
        }
        return builtInModelLocalPaths[modelID.rawValue]
    }

    func setLocalModelPath(_ path: String?, for modelID: BuiltInModelID) {
        stopAccessingLocalModel(for: modelID)
        builtInModelLocalPaths[modelID.rawValue] = path
        builtInModelLocalBookmarks[modelID.rawValue] = nil
    }

    func localModelURL(for modelID: BuiltInModelID) -> URL? {
        resolveLocalModelURL(for: modelID, startAccessing: true)
    }

    func setLocalModelURL(_ url: URL?, for modelID: BuiltInModelID) {
        stopAccessingLocalModel(for: modelID)
        builtInModelLocalPaths[modelID.rawValue] = url?.path
        builtInModelLocalBookmarks[modelID.rawValue] = makeBookmarkString(for: url)
    }

    /// The language chosen for this model, or `nil` for auto-detect. Absence *is* the default,
    /// which is why there is no sentinel string here to collide with a real language code.
    func languageCode(for modelID: BuiltInModelID) -> String? {
        builtInModelLanguages[modelID.rawValue]
    }

    /// Nothing is validated on the way in. A stored language that a model cannot currently
    /// offer is resolved away on read, so choosing Spanish, repointing at an English-only
    /// folder, and repointing back leaves the Spanish intact.
    func setLanguageCode(_ code: String?, for modelID: BuiltInModelID) {
        builtInModelLanguages[modelID.rawValue] = code
    }

    func detectedLanguageCapability(for modelID: BuiltInModelID) -> ModelLanguageCapability? {
        guard let stored = builtInModelLanguageCapabilities[modelID.rawValue] else { return nil }
        return ModelLanguageCapability(storageValue: stored)
    }

    /// Recorded on every model load, including the cached one before each dictation, so it has
    /// to stay silent when nothing changed — otherwise every transcription would republish the
    /// store and redraw the settings pane for no reason.
    func setDetectedLanguageCapability(
        _ capability: ModelLanguageCapability,
        for modelID: BuiltInModelID
    ) {
        guard builtInModelLanguageCapabilities[modelID.rawValue] != capability.storageValue else {
            return
        }
        builtInModelLanguageCapabilities[modelID.rawValue] = capability.storageValue
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

    private func resolveTranscriptFolderURL(startAccessing: Bool) -> URL? {
        if startAccessing, let activeTranscriptFolderURL {
            return activeTranscriptFolderURL
        }

        guard !transcriptFolderBookmark.isEmpty else { return nil }
        let resolved = resolveBookmark(transcriptFolderBookmark, startAccessing: startAccessing)

        if startAccessing {
            activeTranscriptFolderURL = resolved.activeURL
        }

        return resolved.url
    }

    private func resolveLocalModelURL(for modelID: BuiltInModelID, startAccessing: Bool) -> URL? {
        let key = modelID.rawValue
        if startAccessing, let activeURL = activeSecurityScopedModelURLs[key] {
            return activeURL
        }

        guard let bookmark = builtInModelLocalBookmarks[key], !bookmark.isEmpty else { return nil }
        let resolved = resolveBookmark(bookmark, startAccessing: startAccessing)

        if startAccessing, let activeURL = resolved.activeURL {
            activeSecurityScopedModelURLs[key] = activeURL
        }

        return resolved.url
    }

    private func stopAccessingTranscriptFolder() {
        activeTranscriptFolderURL?.stopAccessingSecurityScopedResource()
        activeTranscriptFolderURL = nil
    }

    private func stopAccessingLocalModel(for modelID: BuiltInModelID) {
        activeSecurityScopedModelURLs.removeValue(forKey: modelID.rawValue)?
            .stopAccessingSecurityScopedResource()
    }

    private func makeBookmarkString(for url: URL?) -> String? {
        guard let url else { return nil }

        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data.base64EncodedString()
        }

        if let data = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data.base64EncodedString()
        }

        return nil
    }

    private func resolveBookmark(_ bookmark: String, startAccessing: Bool) -> (url: URL?, activeURL: URL?) {
        guard let data = Data(base64Encoded: bookmark) else {
            return (nil, nil)
        }

        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            let didStartAccess = startAccessing ? url.startAccessingSecurityScopedResource() : false
            return (url, didStartAccess ? url : nil)
        }

        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return (url, nil)
        }

        return (nil, nil)
    }

    private enum Keys {
        static let transcriptFolder      = "transcriptFolderPath"
        static let transcriptFolderBookmark = "transcriptFolderBookmark"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let launchAtLogin         = "launchAtLogin"
        static let toggleKeyCode         = "toggleKeyCode"
        static let toggleModifiers       = "toggleModifiers"
        static let pttKeyCode            = "pttKeyCode"
        static let pttModifiers          = "pttModifiers"
        static let aiActionKeyCode       = "aiActionKeyCode"
        static let aiActionModifiers     = "aiActionModifiers"
        static let selectedBuiltInModelID = "selectedBuiltInModelID"
        static let builtInModelLocalPaths = "builtInModelLocalPaths"
        static let builtInModelLocalBookmarks = "builtInModelLocalBookmarks"
        static let builtInModelLanguages = "builtInModelLanguages"
        static let builtInModelLanguageCapabilities = "builtInModelLanguageCapabilities"
        static let smartFormattingEnabled = "smartFormattingEnabled"
        static let aiActionMasterPrompt = "aiActionMasterPrompt"
        static let openRouterKeyRejected = "openRouterKeyRejected"
        static let openRouterOutOfCredit = "openRouterOutOfCredit"
        static let openRouterKeyVerified = "openRouterKeyVerified"
    }
}
