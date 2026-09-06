import Foundation
import WhisperKit

/// One entry in a model's language control.
///
/// `autoDetect` is not a language, it is the absence of a choice — which the decoder reads as
/// "work it out from the audio". Keeping it in the same type as the languages leaves the
/// control with one list to render and one value to compare against.
enum TranscriptionLanguageOption: Equatable, Hashable, Identifiable {
    case autoDetect
    case language(code: String)

    var id: String {
        switch self {
        case .autoDetect:         return "auto"
        case .language(let code): return code
        }
    }

    var title: String {
        switch self {
        case .autoDetect:         return "Auto-detect"
        case .language(let code): return TranscriptionLanguageCatalog.displayName(for: code)
        }
    }

    /// What reaches `DecodingOptions.language`. `nil` is the meaningful case: it is what turns
    /// detection back on.
    var decodingLanguageCode: String? {
        switch self {
        case .autoDetect:         return nil
        case .language(let code): return code
        }
    }
}

/// The languages Whisper can decode, named the way the user reads them.
enum TranscriptionLanguageCatalog {
    /// Whisper publishes 112 name→code pairs but only 100 distinct codes: `castilian` and
    /// `spanish` are both `es`, `mandarin` and `chinese` are both `zh`. Keying by code is what
    /// stops Spanish appearing in the menu twice, and it spares us from having to pick a
    /// winner between spellings like `pushto` and `pashto`.
    static let supportedCodes: Set<String> = Set(Constants.languages.values)

    /// Sorted by the name shown rather than by code, so the order stays right for the reader
    /// and re-sorts itself correctly if the app is ever localized.
    static let allOptions: [TranscriptionLanguageOption] = supportedCodes
        .map { TranscriptionLanguageOption.language(code: $0) }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

    /// Every option a multilingual model offers, built once: three rows re-evaluating their
    /// bodies should not each rebuild a 101-element array.
    static let multilingualOptions: [TranscriptionLanguageOption] = [.autoDetect] + allOptions

    /// Apple and Whisper disagree on exactly two codes that a real user might have configured.
    /// Whisper predates the ISO 639 revision that gave Javanese `jv`, and it has no Bokmål at
    /// all — plain `no` is as close as it gets. Without these, a Norwegian looking at the
    /// shortcut section would not find their own language in it.
    private static let systemCodeAliases = ["jv": "jw", "nb": "no"]

    /// The user's own languages, for the top of the menu. Read from the system rather than
    /// from an opinion about which languages are worth promoting.
    static var preferredOptions: [TranscriptionLanguageOption] {
        var seen: Set<String> = []
        return Locale.preferredLanguages.compactMap { identifier in
            guard let raw = Locale.Language(identifier: identifier).languageCode?.identifier else {
                return nil
            }
            let code = systemCodeAliases[raw] ?? raw
            guard supportedCodes.contains(code), seen.insert(code).inserted else { return nil }
            return .language(code: code)
        }
    }

    static func displayName(for code: String) -> String {
        if let name = Locale.current.localizedString(forLanguageCode: code) {
            return name
        }

        // Every code Whisper currently ships resolves above, so this only catches one a future
        // WhisperKit adds. Taking the alphabetically first spelling keeps the fallback
        // deterministic rather than dependent on dictionary ordering.
        return Constants.languages
            .filter { $0.value == code }
            .keys
            .sorted()
            .first?
            .capitalized ?? code.uppercased()
    }

    static func isSupported(_ code: String) -> Bool {
        supportedCodes.contains(code)
    }
}

/// What a model can actually decode.
///
/// Models whose checkpoint we pin declare this in the catalog. A folder the user supplied has
/// to be measured — WhisperKit derives it from the decoder's output dimension as the model
/// loads — so until that folder has been loaded at least once, `unknown` is the honest answer
/// and the row shows no language control at all.
enum ModelLanguageCapability: Equatable, Sendable {
    case single(code: String)
    case multilingual
    case unknown
}

extension ModelLanguageCapability {
    /// `unknown` deliberately has no stored form: not knowing is the absence of a record, so
    /// it round-trips as a missing key rather than as a value meaning "no".
    var storageValue: String? {
        switch self {
        case .multilingual:       return "multilingual"
        case .single(let code):   return "single:\(code)"
        case .unknown:            return nil
        }
    }

    init?(storageValue: String) {
        if storageValue == "multilingual" {
            self = .multilingual
            return
        }

        let singlePrefix = "single:"
        guard storageValue.hasPrefix(singlePrefix) else { return nil }
        let code = String(storageValue.dropFirst(singlePrefix.count))
        guard !code.isEmpty else { return nil }
        self = .single(code: code)
    }
}

/// The trailing language control for one row: what it currently reads, and where it can go.
struct ModelLanguageControl: Equatable {
    /// Every option this model offers, deduplicated. The menu may show some of them twice.
    let options: [TranscriptionLanguageOption]
    let selection: TranscriptionLanguageOption
    /// Menu layout, with a divider drawn between groups. Entries repeat across groups by
    /// design — that is how the user's own languages sit at the top as well as in place.
    let optionGroups: [[TranscriptionLanguageOption]]

    /// A menu and a chevron are earned by having somewhere to go, never by being a particular
    /// model. A Parakeet that one day ships multilingual weights picks both up for free.
    var allowsSelection: Bool { options.count > 1 }
}

enum ModelLanguageResolver {
    /// Measurement only speaks for folders we did not choose. A model whose checkpoint we pin
    /// describes itself, and is not second-guessed by whatever was last loaded.
    static func capability(
        for model: BuiltInModelDescriptor,
        detected: ModelLanguageCapability?
    ) -> ModelLanguageCapability {
        guard case .unknown = model.declaredLanguageCapability else {
            return model.declaredLanguageCapability
        }
        return detected ?? .unknown
    }

    static func control(
        for model: BuiltInModelDescriptor,
        detected: ModelLanguageCapability?,
        storedCode: String?
    ) -> ModelLanguageControl? {
        switch capability(for: model, detected: detected) {
        case .unknown:
            return nil

        case .single(let code):
            let only = TranscriptionLanguageOption.language(code: code)
            return ModelLanguageControl(options: [only], selection: only, optionGroups: [[only]])

        case .multilingual:
            let options = TranscriptionLanguageCatalog.multilingualOptions
            let groups = [
                [TranscriptionLanguageOption.autoDetect],
                TranscriptionLanguageCatalog.preferredOptions,
                TranscriptionLanguageCatalog.allOptions,
            ].filter { !$0.isEmpty }

            return ModelLanguageControl(
                options: options,
                selection: resolve(storedCode: storedCode, in: options),
                optionGroups: groups
            )
        }
    }

    /// What the decoder should be told for this model right now. `nil` asks it to detect.
    static func decodingLanguageCode(
        for model: BuiltInModelDescriptor,
        detected: ModelLanguageCapability?,
        storedCode: String?
    ) -> String? {
        control(for: model, detected: detected, storedCode: storedCode)?
            .selection
            .decodingLanguageCode
    }

    /// Resolution happens on read rather than on write, so a stored language survives being
    /// temporarily impossible: point a folder at an English-only checkpoint and back again,
    /// and the Spanish that was chosen is still there. Clearing on change would have destroyed
    /// it, and would still have missed values written by a hand-edited plist or a later build.
    private static func resolve(
        storedCode: String?,
        in options: [TranscriptionLanguageOption]
    ) -> TranscriptionLanguageOption {
        guard let storedCode else { return options[0] }
        let stored = TranscriptionLanguageOption.language(code: storedCode)
        return options.contains(stored) ? stored : options[0]
    }
}
