import CoreML
import FluidAudio
import Foundation
import WhisperKit

struct ModelInstallProgress: Sendable {
    let fractionCompleted: Double?
    let phase: String
}

typealias ModelInstallProgressHandler = @Sendable (ModelInstallProgress) -> Void

enum NativeModelInstallState: Equatable {
    case checking
    case notInstalled
    case downloading(progress: Double?, phase: String)
    case ready
    case failed(String)
}
