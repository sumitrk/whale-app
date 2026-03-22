import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// AudioRecorder is NOT @MainActor so SCStream callbacks (background queue)
// can safely touch sample buffers (protected by NSLock).
// Public API methods that set @Published state are individually @MainActor.
class AudioRecorder: NSObject, ObservableObject {

    // MARK: - State

    @Published var isRecording = false

    // MARK: - System audio (ScreenCaptureKit)

    private var scStream: SCStream?

    // MARK: - Microphone (AVAudioEngine)

    private var micEngine: AVAudioEngine?

    // MARK: - Sample buffers (lock-protected)

    /// Raw samples from SCStream, already at targetSampleRate (16 kHz), stereo→mono averaged.
    private var systemAudioSamples: [Float] = []
    /// Samples from mic already resampled to targetSampleRate.
    private var micSamples: [Float] = []
    private let lock = NSLock()

    /// Rate Whisper expects. SCStream is configured to output at this rate directly.
    private let targetSampleRate: Double = 16_000

    // MARK: - Public API

    @MainActor
    func startRecording() async throws {
        guard !isRecording else { return }

        systemAudioSamples = []
        micSamples = []

        try await startSystemAudioCapture()
        try startMicCapture()

        isRecording = true
        print("AudioRecorder: recording started")
    }

    @MainActor
    func stopRecording() async throws -> URL {
        guard isRecording else { throw RecorderError.notRecording }

        await stopSystemAudioCapture()
        stopMicCapture()

        isRecording = false
        print("AudioRecorder: recording stopped")

        return try mixAndWriteWAV()
    }

    // MARK: - Meetings folder

    static func meetingsFolder() -> URL {
        let projectMeetings = URL(fileURLWithPath:
            "/Users/sumitkumar/Downloads/Projects/transcribe-meetings/meetings")
        if (try? FileManager.default.createDirectory(
                at: projectMeetings, withIntermediateDirectories: true)) != nil
            || FileManager.default.fileExists(atPath: projectMeetings.path) {
            return projectMeetings
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let folder = docs.appendingPathComponent("TranscribeMeetings")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - ScreenCaptureKit system audio

    private func startSystemAudioCapture() async throws {
        // Get available displays — SCStream needs a content filter even for audio-only capture.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            throw RecorderError.screenCapturePermissionDenied
        }

        guard let display = content.displays.first else {
            throw RecorderError.noDisplayFound
        }

        // Filter: capture everything (all apps, all windows).
        // We don't exclude our own app since we produce no audio.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        // Audio-only config — SCStream outputs Float32 non-interleaved.
        // Setting width/height to 2 and 1 fps minimises the video overhead
        // (we never add a .screen output so no frames are actually delivered).
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(targetSampleRate)   // 16 000 Hz — no resampling needed
        config.channelCount = 2                     // stereo; we average to mono on receipt
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        // Add only the audio output — macOS registers us under "System Audio Recording Only".
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
        try await stream.startCapture()
        self.scStream = stream
        print("AudioRecorder: SCStream audio capture started (\(Int(targetSampleRate)) Hz, audio-only)")
    }

    private func stopSystemAudioCapture() async {
        guard let stream = scStream else { return }
        try? await stream.stopCapture()
        scStream = nil
    }

    // MARK: - Extract mono Float32 from SCStream CMSampleBuffer

    private func extractMonoSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return [] }

        // Two-pass: first get the required buffer list size, then fill it.
        var bufferListSizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        )
        guard bufferListSizeNeeded > 0 else { return [] }

        let ablData = UnsafeMutableRawPointer.allocate(byteCount: bufferListSizeNeeded, alignment: 16)
        defer { ablData.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablData.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: bufferListSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return [] }
        _ = blockBuffer  // keep alive until we're done reading

        // SCStream delivers non-interleaved Float32: one AudioBuffer per channel.
        // Average all channels into mono.
        let abl = UnsafeMutableAudioBufferListPointer(
            ablData.assumingMemoryBound(to: AudioBufferList.self))
        guard abl.count > 0 else { return [] }

        var mono = [Float](repeating: 0, count: numSamples)
        let divisor = Float(abl.count)
        for buf in abl {
            guard let data = buf.mData else { continue }
            let ptr = data.bindMemory(to: Float.self, capacity: numSamples)
            for i in 0..<numSamples {
                mono[i] += ptr[i] / divisor
            }
        }
        return mono
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        let engine     = AVAudioEngine()
        let inputNode  = engine.inputNode
        let inputFmt   = inputNode.outputFormat(forBus: 0)

        guard let targetFmt = AVAudioFormat(
            standardFormatWithSampleRate: targetSampleRate, channels: 1
        ) else { throw RecorderError.formatError }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFmt) {
            [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.convertAndExtract(buffer, from: inputFmt, to: targetFmt)
            self.lock.lock()
            self.micSamples.append(contentsOf: samples)
            self.lock.unlock()
        }

        try engine.start()
        self.micEngine = engine
        print("AudioRecorder: microphone capture started")
    }

    private func stopMicCapture() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
    }

    // MARK: - Mix + Write WAV

    private func mixAndWriteWAV() throws -> URL {
        lock.lock()
        let sys = systemAudioSamples   // already at 16 kHz — no resampling needed
        let mic = micSamples
        lock.unlock()

        let length = max(sys.count, mic.count)
        guard length > 0 else { throw RecorderError.noAudioCaptured }

        let sysPad = sys + [Float](repeating: 0, count: max(0, length - sys.count))
        let micPad = mic + [Float](repeating: 0, count: max(0, length - mic.count))

        var mixed = [Float](repeating: 0, count: length)
        for i in 0..<length {
            mixed[i] = (sysPad[i] + micPad[i]) / 2.0
        }

        let int16 = mixed.map { s -> Int16 in
            Int16(max(-1.0, min(1.0, s)) * Float(Int16.max))
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .replacingOccurrences(of: "Z", with: "")
        let url = Self.meetingsFolder().appendingPathComponent("meeting-\(stamp).wav")
        try writeWAV(samples: int16, sampleRate: Int(targetSampleRate), to: url)

        let kb = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
        print("AudioRecorder: WAV saved → \(url.lastPathComponent) (\(kb / 1024) KB)")
        return url
    }

    // MARK: - WAV writer

    private func writeWAV(samples: [Int16], sampleRate: Int, to url: URL) throws {
        var data = Data()
        let dataSize = samples.count * 2
        let byteRate = sampleRate * 2   // 16-bit mono

        data.appendString("RIFF")
        data.appendUInt32(UInt32(36 + dataSize))
        data.appendString("WAVE")
        data.appendString("fmt ")
        data.appendUInt32(16)
        data.appendUInt16(1)                        // PCM
        data.appendUInt16(1)                        // mono
        data.appendUInt32(UInt32(sampleRate))
        data.appendUInt32(UInt32(byteRate))
        data.appendUInt16(2)                        // block align
        data.appendUInt16(16)                       // bits per sample
        data.appendString("data")
        data.appendUInt32(UInt32(dataSize))
        for s in samples { data.appendUInt16(UInt16(bitPattern: s)) }

        try data.write(to: url)
    }

    // MARK: - Audio format converter (mic tap → 16 kHz mono)

    private func convertAndExtract(_ buffer: AVAudioPCMBuffer,
                                   from: AVAudioFormat,
                                   to: AVAudioFormat) -> [Float] {
        guard let converter = AVAudioConverter(from: from, to: to) else { return [] }
        let ratio     = to.sampleRate / from.sampleRate
        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let out = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: outFrames) else { return [] }
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channelData = out.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(out.frameLength)))
    }
}

// MARK: - SCStreamDelegate

extension AudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("AudioRecorder: SCStream stopped with error: \(error.localizedDescription)")
    }
}

// MARK: - SCStreamOutput

extension AudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        let samples = extractMonoSamples(from: sampleBuffer)
        guard !samples.isEmpty else { return }
        lock.lock()
        systemAudioSamples.append(contentsOf: samples)
        lock.unlock()
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case notRecording
    case noDisplayFound
    case screenCapturePermissionDenied
    case formatError
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .notRecording:
            return "Not currently recording"
        case .noDisplayFound:
            return "No display found for audio capture"
        case .screenCapturePermissionDenied:
            return "Screen & System Audio Recording permission denied. Grant it in System Settings → Privacy & Security."
        case .formatError:
            return "Audio format conversion failed"
        case .noAudioCaptured:
            return "No audio was captured"
        }
    }
}

// MARK: - Data WAV helpers

private extension Data {
    mutating func appendString(_ s: String) { append(contentsOf: s.utf8) }
    mutating func appendUInt16(_ v: UInt16) { var x = v.littleEndian; append(Data(bytes: &x, count: 2)) }
    mutating func appendUInt32(_ v: UInt32) { var x = v.littleEndian; append(Data(bytes: &x, count: 4)) }
}
