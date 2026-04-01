import AppKit
import Foundation

enum OutputMode: Sendable {
    case paste
    case markdown
}

enum CleanupLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case light
    case medium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light:
            return "Light"
        case .medium:
            return "Medium"
        }
    }

    var detail: String {
        switch self {
        case .light:
            return "Minimal local AI cleanup"
        case .medium:
            return "Stronger local AI cleanup"
        }
    }
}

struct FocusedAppContext: Sendable, Equatable {
    let appName: String?
    let bundleIdentifier: String?

    static func capture() -> FocusedAppContext? {
        let app = NSWorkspace.shared.frontmostApplication
        guard app != nil else { return nil }
        return FocusedAppContext(
            appName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier
        )
    }
}

enum LocalLLMModelID: String, CaseIterable, Codable, Identifiable, Sendable {
    case qwen3_0_6b_4bit

    var id: String { rawValue }

    var descriptor: LocalLLMModelDescriptor {
        LocalLLMModelCatalog.descriptor(for: self)
    }
}

struct LocalLLMModelDescriptor: Identifiable, Equatable, Sendable {
    let id: LocalLLMModelID
    let title: String
    let detail: String
    let repoID: String
    let sizeLabel: String
    let recommended: Bool
}

enum LocalLLMModelCatalog {
    static let allModels: [LocalLLMModelDescriptor] = [
        LocalLLMModelDescriptor(
            id: .qwen3_0_6b_4bit,
            title: "Qwen 3 0.6B",
            detail: "MLX 4-bit • ultra-fast local cleanup • recommended default",
            repoID: "mlx-community/Qwen3-0.6B-4bit",
            sizeLabel: "~0.4 GB",
            recommended: true
        ),
    ]

    static func descriptor(for id: LocalLLMModelID) -> LocalLLMModelDescriptor {
        guard let descriptor = allModels.first(where: { $0.id == id }) else {
            preconditionFailure("Unknown local LLM model id: \(id.rawValue)")
        }
        return descriptor
    }
}

struct TextCleanupSettings: Sendable, Equatable {
    let enabled: Bool
    let cleanupLevel: CleanupLevel
    let localLLMModelID: LocalLLMModelID?

    init(
        enabled: Bool,
        cleanupLevel: CleanupLevel,
        localLLMModelID: LocalLLMModelID?
    ) {
        self.enabled = enabled
        self.cleanupLevel = cleanupLevel
        self.localLLMModelID = localLLMModelID
    }

    @MainActor
    init(store: SettingsStore) {
        self.enabled = store.postProcessingEnabled
        self.cleanupLevel = store.cleanupLevel
        self.localLLMModelID = store.selectedLocalLLMModelID
    }
}
