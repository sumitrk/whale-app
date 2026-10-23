import CoreML
import FluidAudio
import Foundation
import WhisperKit

enum LocalTranscriptionError: LocalizedError {
    case modelNotInstalled(BuiltInModelDescriptor)
    case notInitialized(BuiltInModelDescriptor)
    case unsupportedModel(BuiltInModelID)
    case appleSpeechUnavailable(String)
    case parakeetSetupFailed(
        step: ParakeetInstallStep,
        modelDirectory: String,
        reason: String
    )
    case invalidWhisperModelFolder(
        descriptor: BuiltInModelDescriptor,
        folderPath: String,
        issues: [String]
    )

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled(let descriptor):
            return descriptor.installationPrompt
        case .notInitialized(let descriptor):
            return "\(descriptor.title) is not ready yet."
        case .unsupportedModel(let modelID):
            return "Unsupported transcription model: \(modelID.rawValue)"
        case .appleSpeechUnavailable(let reason):
            return reason
        case .parakeetSetupFailed(let step, let modelDirectory, let reason):
            return """
            FluidAudio English could not be prepared.

            Step:
            \(step.title)

            Storage:
            \(modelDirectory)

            Reason:
            \(reason)

            Use Delete in Settings > Models, then install Parakeet again.
            """
        case .invalidWhisperModelFolder(let descriptor, let folderPath, let issues):
            let bulletList = issues.map { "• \($0)" }.joined(separator: "\n")

            return """
            \(descriptor.title) could not be loaded.

            Folder:
            \(folderPath)

            Problems:
            \(bulletList)

            Choose a WhisperKit/Core ML folder that contains MelSpectrogram, AudioEncoder, and TextDecoder.
            """
        }
    }
}
