import CoreML
import FluidAudio
import Foundation
import WhisperKit

protocol BuiltInTranscriptionBackend: Sendable {
    func isInstalled(modelID: BuiltInModelID) async throws -> Bool
    func prepare(modelID: BuiltInModelID) async throws
    func install(
        modelID: BuiltInModelID,
        progressHandler: ModelInstallProgressHandler?
    ) async throws
    func connectLocalModel(
        modelID: BuiltInModelID,
        folderURL: URL,
        progressHandler: ModelInstallProgressHandler?
    ) async throws
    func transcribe(
        modelID: BuiltInModelID,
        wavURL: URL,
        source: AudioSource
    ) async throws -> String
    func resetModel(modelID: BuiltInModelID) async throws
}

extension BuiltInTranscriptionBackend {
    func prepare(modelID: BuiltInModelID) async throws {
        throw LocalTranscriptionError.unsupportedModel(modelID)
    }

    func connectLocalModel(
        modelID: BuiltInModelID,
        folderURL _: URL,
        progressHandler _: ModelInstallProgressHandler?
    ) async throws {
        throw LocalTranscriptionError.unsupportedModel(modelID)
    }

    func resetModel(modelID: BuiltInModelID) async throws {
        throw LocalTranscriptionError.unsupportedModel(modelID)
    }
}
