import AVFoundation
import FluidAudio
import Foundation
import Speech

/// Apple's own on-device recogniser, offered beside Parakeet and Whisper so the three can be
/// compared on the same recordings.
///
/// The model is a system asset: macOS downloads it, shares it between apps, and decides when
/// to evict it. So there is no folder to show and nothing here to delete.
actor AppleSpeechTranscriptionBackend: BuiltInTranscriptionBackend {
    func isInstalled(modelID _: BuiltInModelID) async throws -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return await AssetInventory.status(forModules: [Self.makeTranscriber()]) == .installed
    }

    /// Nothing to warm up: the analyzer is built per recording and loads in well under a second.
    func prepare(modelID _: BuiltInModelID) async throws {}

    func install(
        modelID _: BuiltInModelID,
        progressHandler: ModelInstallProgressHandler?
    ) async throws {
        guard #available(macOS 26.0, *) else {
            throw LocalTranscriptionError.appleSpeechUnavailable("Apple Speech needs macOS 26 or later.")
        }

        let transcriber = await Self.makeTranscriber()
        guard await AssetInventory.status(forModules: [transcriber]) != .unsupported else {
            throw LocalTranscriptionError.appleSpeechUnavailable(
                "Apple Speech is not available for English on this Mac."
            )
        }

        // `nil` means the asset is already on this Mac, put there by the system or another app.
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }

        let observation = request.progress.observe(\.fractionCompleted, options: [.initial]) { progress, _ in
            progressHandler?(
                ModelInstallProgress(
                    fractionCompleted: progress.fractionCompleted,
                    phase: "Downloading model"
                )
            )
        }
        defer { observation.invalidate() }

        try await request.downloadAndInstall()
    }

    func transcribe(
        modelID: BuiltInModelID,
        wavURL: URL,
        source _: AudioSource
    ) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw LocalTranscriptionError.appleSpeechUnavailable("Apple Speech needs macOS 26 or later.")
        }

        let transcriber = await Self.makeTranscriber()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw LocalTranscriptionError.modelNotInstalled(modelID.descriptor)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: wavURL)

        // Results only arrive while the analyzer is being fed, so the collection has to be
        // running before the file goes in rather than awaited after it.
        async let transcript = transcriber.results.reduce(into: "") { text, result in
            text += String(result.text.characters)
        }

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return try await transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Mac's own English, so "en-IN" is heard as Indian English rather than forced
    /// through the American model. Anything that is not English falls back to en-US, because
    /// the row promises English and nothing else.
    @available(macOS 26.0, *)
    private static func makeTranscriber() async -> SpeechTranscriber {
        var locale = Locale(identifier: "en-US")
        if Locale.current.language.languageCode == .english,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            locale = supported
        }
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }
}
