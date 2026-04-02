import Foundation

struct LocalLLMCleanupStage: PipelineStage {
    static let stageName = "Local LLM Cleanup"
    private enum ChunkingPolicy {
        static let pasteTargetWords = 28
        static let pasteMaxWords = 40
        static let pasteMaxCharacters = 220
        static let markdownMaxWords = 1_500
    }

    let name = stageName
    let isRecoverable = true

    private let service: LocalLLMService?
    private let clean: @Sendable (String, PipelineContext, TimeInterval?) async throws -> String

    init(
        service: LocalLLMService = .shared,
        clean: (@Sendable (String, PipelineContext, TimeInterval?) async throws -> String)? = nil
    ) {
        self.service = clean == nil ? service : nil
        if let clean {
            self.clean = clean
        } else {
            self.clean = { transcript, context, timeout in
                guard let modelID = context.postProcessingSettings.localLLMModelID else {
                    return transcript
                }
                guard try await service.isModelInstalled(modelID) else {
                    throw LocalLLMError.modelNotInstalled(modelID.descriptor.title)
                }

                return try await service.cleanTranscript(
                    transcript: transcript,
                    focusedAppContext: context.focusedAppContext,
                    cleanupLevel: context.postProcessingSettings.cleanupLevel,
                    cleanupPromptOverride: context.postProcessingSettings.cleanupPromptOverride,
                    modelID: modelID,
                    outputMode: context.outputMode,
                    timeout: timeout
                )
            }
        }
    }

    func process(_ context: PipelineContext) async throws -> PipelineContext {
        guard context.postProcessingSettings.enabled,
              context.postProcessingSettings.localLLMModelID != nil else {
            return context
        }
        guard !context.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return context
        }

        var updated = context
        updated.didRunLocalLLM = true

        let timeout: TimeInterval? = switch context.outputMode {
        case .paste:
            nil
        case .markdown:
            nil
        }

        let chunks = chunkedTranscript(context.transcript, outputMode: context.outputMode)
        var cleanedChunks: [String] = []
        cleanedChunks.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()

            if chunks.count > 1 {
                context.progressHandler("Cleaning up transcript… (chunk \(index + 1)/\(chunks.count))")
            } else {
                context.progressHandler("Cleaning up…")
            }

            let cleaned = try await clean(chunk, context, timeout)
            cleanedChunks.append(cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let separator: String
        switch context.outputMode {
        case .paste:
            separator = " "
        case .markdown:
            separator = "\n\n"
        }
        updated.transcript = cleanedChunks.joined(separator: chunks.count > 1 ? separator : "")
        return updated
    }

    private func chunkedTranscript(_ transcript: String, outputMode: OutputMode) -> [String] {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        switch outputMode {
        case .paste:
            return chunkedPasteTranscript(trimmed)
        case .markdown:
            return chunkedByWords(trimmed, maxWords: ChunkingPolicy.markdownMaxWords)
        }
    }

    private func chunkedPasteTranscript(_ transcript: String) -> [String] {
        let totalWords = wordCount(in: transcript)
        if totalWords <= ChunkingPolicy.pasteTargetWords,
           transcript.count <= ChunkingPolicy.pasteMaxCharacters {
            return [transcript]
        }

        let sentenceSegments = sentenceSegments(in: transcript)
        guard sentenceSegments.count > 1 else {
            return chunkedByWords(transcript, maxWords: ChunkingPolicy.pasteTargetWords)
        }

        var chunks: [String] = []
        var currentSentences: [String] = []
        var currentWordCount = 0
        var currentCharacterCount = 0

        func flush() {
            guard !currentSentences.isEmpty else { return }
            chunks.append(currentSentences.joined(separator: " "))
            currentSentences.removeAll(keepingCapacity: true)
            currentWordCount = 0
            currentCharacterCount = 0
        }

        for sentence in sentenceSegments {
            let sentenceWordCount = wordCount(in: sentence)
            let sentenceCharacterCount = sentence.count

            if sentenceWordCount > ChunkingPolicy.pasteMaxWords
                || sentenceCharacterCount > ChunkingPolicy.pasteMaxCharacters {
                flush()
                chunks.append(contentsOf: chunkedByWords(sentence, maxWords: ChunkingPolicy.pasteTargetWords))
                continue
            }

            let wouldExceedWords = currentWordCount + sentenceWordCount > ChunkingPolicy.pasteMaxWords
            let separatorCharacters = currentSentences.isEmpty ? 0 : 1
            let wouldExceedCharacters = currentCharacterCount + separatorCharacters + sentenceCharacterCount > ChunkingPolicy.pasteMaxCharacters

            if wouldExceedWords || wouldExceedCharacters {
                flush()
            }

            currentSentences.append(sentence)
            currentWordCount += sentenceWordCount
            currentCharacterCount += separatorCharacters + sentenceCharacterCount
        }

        flush()

        return chunks.isEmpty ? [transcript] : chunks
    }

    private func chunkedByWords(_ transcript: String, maxWords: Int) -> [String] {
        let words = transcript.split(whereSeparator: \.isWhitespace)
        guard words.count > maxWords else { return [transcript] }

        var chunks: [String] = []
        var start = 0

        while start < words.count {
            let end = min(words.count, start + maxWords)
            let chunk = words[start..<end].joined(separator: " ")
            chunks.append(chunk)

            if end == words.count { break }
            start = end
        }

        return chunks
    }

    private func sentenceSegments(in transcript: String) -> [String] {
        var segments: [String] = []

        transcript.enumerateSubstrings(
            in: transcript.startIndex..<transcript.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let sentence = transcript[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                segments.append(sentence)
            }
        }

        return segments
    }

    private func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
