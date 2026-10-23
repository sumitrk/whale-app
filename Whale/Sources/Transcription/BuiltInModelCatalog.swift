import CoreML
import FluidAudio
import Foundation
import WhisperKit

enum BuiltInModelGroup: String, CaseIterable, Codable, Identifiable, Sendable {
    case parakeet
    case whisper
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet:
            return "Parakeet"
        case .whisper:
            return "Whisper"
        case .apple:
            return "Apple"
        }
    }
}

enum BuiltInModelProvisioning: String, Codable, Sendable {
    case download
    case localFolder
    /// A model macOS downloads, shares between apps, and evicts on its own schedule.
    case systemAsset
}

enum BuiltInModelID: String, CaseIterable, Codable, Identifiable, Sendable {
    case parakeetEnglishV2
    case barkCleanEnglish
    case whisperLargeV3Turbo
    case whisperLocalFolder
    case appleSpeech

    var id: String { rawValue }

    var descriptor: BuiltInModelDescriptor {
        BuiltInModelCatalog.descriptor(for: self)
    }
}

/// Which box a model lives in on the Models settings pane: models Whale ships and can
/// install itself, versus a checkpoint the user points at on disk.
enum BuiltInModelSource: String, Codable, CaseIterable, Sendable {
    case bundled
    case custom
}

struct BuiltInModelDescriptor: Identifiable, Equatable, Sendable {
    let id: BuiltInModelID
    let group: BuiltInModelGroup
    let source: BuiltInModelSource
    let provisioning: BuiltInModelProvisioning
    let title: String
    /// Short capability blurb shown after the status while the row has no language control —
    /// before install, and while it needs attention. Once a language control appears it says
    /// the same thing more precisely, so the two are never shown at once.
    let capabilityLabel: String
    /// What this model can decode, for models whose checkpoint we pin. `unknown` means the
    /// answer has to be measured when the model loads, which is only true of a folder the
    /// user supplied.
    let declaredLanguageCapability: ModelLanguageCapability
    let detail: String
    let markdownLabel: String
    /// What the download weighs, shown before it's installed. Nil for models macOS provides.
    var downloadSize: String? = nil

    var installationPrompt: String {
        switch provisioning {
        case .download, .systemAsset:
            return "\(title) is not downloaded. Open Settings > Models and download it."
        case .localFolder:
            return "\(title) is not configured yet. Open Settings > Models, choose a WhisperKit/Core ML folder, and try again."
        }
    }

    var actionTitle: String {
        switch provisioning {
        case .download, .systemAsset:
            return "Download"
        case .localFolder:
            return "Choose folder"
        }
    }

    var retryActionTitle: String {
        switch provisioning {
        case .download, .systemAsset:
            return "Retry"
        case .localFolder:
            return "Choose another folder"
        }
    }

    var changeActionTitle: String? {
        switch provisioning {
        case .download, .systemAsset:
            return nil
        case .localFolder:
            return "Change folder"
        }
    }

    /// Whether the app put these files on disk and may therefore take them off again.
    ///
    /// Derived from how the model is provisioned rather than listed per model, so the question
    /// "may we delete this?" can never be answered wrongly for a model added later: anything
    /// the app downloads it owns, anything the user points it at belongs to the user.
    var ownsModelFiles: Bool {
        switch provisioning {
        case .download:    return true
        case .localFolder: return false
        case .systemAsset: return false
        }
    }

    /// Named for what it does rather than for the cache-clearing it used to imply — the next
    /// use has to download the model again.
    ///
    /// A folder the user converted themselves is only forgotten, never erased, and the wording
    /// has to say so; the two come from one property so they cannot drift apart.
    var resetActionTitle: String? {
        switch provisioning {
        case .download:    return "Delete"
        case .localFolder: return "Disconnect"
        // The system owns the asset and the app holds no pointer to it: nothing to reset.
        case .systemAsset: return nil
        }
    }
}

enum BuiltInModelCatalog {
    static let allModels: [BuiltInModelDescriptor] = [
        BuiltInModelDescriptor(
            id: .parakeetEnglishV2,
            group: .parakeet,
            source: .bundled,
            provisioning: .download,
            title: "Parakeet",
            capabilityLabel: "English only",
            declaredLanguageCapability: .single(code: "en"),
            detail: "Parakeet TDT v2 • English only • Runs locally on-device",
            markdownLabel: "FluidAudio Parakeet v2",
            downloadSize: "445 MB"
        ),
        // Underdog's name for it, credited as CC-BY asks. Runs on the Parakeet backend because
        // it is a Parakeet v3 fine-tune.
        BuiltInModelDescriptor(
            id: .barkCleanEnglish,
            group: .parakeet,
            source: .bundled,
            provisioning: .download,
            title: BarkCleanModelCatalog.displayName,
            capabilityLabel: "English only · Leaves out “um” and false starts",
            declaredLanguageCapability: .single(code: "en"),
            detail: "Underdog Bark 3.0 Clean (CC BY 4.0) • English only • Runs locally on-device",
            markdownLabel: "Underdog Bark 3.0 Clean",
            downloadSize: "281 MB"
        ),
        BuiltInModelDescriptor(
            id: .whisperLargeV3Turbo,
            group: .whisper,
            source: .bundled,
            provisioning: .download,
            title: "Whisper Large v3 Turbo",
            capabilityLabel: "Multilingual",
            declaredLanguageCapability: .multilingual,
            detail: "WhisperKit • OpenAI Whisper large-v3-turbo • Runs locally on-device",
            markdownLabel: "Whisper Large V3 Turbo",
            downloadSize: "3.2 GB"
        ),
        BuiltInModelDescriptor(
            id: .appleSpeech,
            group: .apple,
            source: .bundled,
            provisioning: .systemAsset,
            title: "Apple Speech",
            capabilityLabel: "English only",
            declaredLanguageCapability: .single(code: "en"),
            detail: "SpeechAnalyzer • Built into macOS 26 • Runs locally on-device",
            markdownLabel: "Apple Speech"
        ),
        BuiltInModelDescriptor(
            id: .whisperLocalFolder,
            group: .whisper,
            source: .custom,
            provisioning: .localFolder,
            title: "Local Whisper Folder",
            // The folder is whatever the user picked, so we can only promise detection,
            // not multilingual support: an English-only checkpoint is a valid choice here.
            capabilityLabel: "Auto-detect",
            // Measured the first time the folder loads, then remembered. Until then the row
            // shows no language control rather than guessing at one.
            declaredLanguageCapability: .unknown,
            detail: "WhisperKit/Core ML • Choose a converted local model folder from your Mac",
            markdownLabel: "Local Whisper Model"
        ),
    ]

    static func descriptor(for id: BuiltInModelID) -> BuiltInModelDescriptor {
        guard let descriptor = allModels.first(where: { $0.id == id }) else {
            preconditionFailure("Unknown built-in model id: \(id.rawValue)")
        }
        return descriptor
    }

    static func models(in group: BuiltInModelGroup) -> [BuiltInModelDescriptor] {
        allModels.filter { $0.group == group }
    }

    /// What the Models pane lists. Apple Speech is left out before macOS 26, where the
    /// system has no such model to offer.
    static func models(from source: BuiltInModelSource) -> [BuiltInModelDescriptor] {
        allModels.filter { $0.source == source && isAvailable($0.group) }
    }

    private static func isAvailable(_ group: BuiltInModelGroup) -> Bool {
        switch group {
        case .parakeet, .whisper:
            return true
        case .apple:
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }
}
