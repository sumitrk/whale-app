# Step 3: Audio Capture (ScreenCaptureKit + Microphone)

## Goal
Record system audio (via ScreenCaptureKit) and microphone (via AVFoundation), mix them together, write to a WAV file, then POST to `/transcribe`. Log the resulting transcript to the console. No UI changes yet — just verify the full audio→transcript path works from Swift.

## What Is Usable After This Step
Press a temporary "Record 10s" button in the menu bar → wait → see the transcript printed in Xcode's debug console. System audio (YouTube, Google Meet, etc.) and your voice are both captured and transcribed.

---

## Permissions (Info.plist additions)

Add these to `TranscribeMeeting/Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>TranscribeMeeting needs microphone access to record your voice during meetings.</string>

<key>NSScreenCaptureUsageDescription</key>
<string>TranscribeMeeting needs screen recording access to capture audio from meeting apps.</string>
```

And in the target's Signing & Capabilities:
- Add **"Audio Input"** entitlement: `com.apple.security.device.audio-input`

---

## Files to Create

### `AudioRecorder.swift`

Handles the full recording lifecycle: start capture → mix channels → write WAV → POST to server.

```swift
import AVFoundation
import ScreenCaptureKit
import Foundation

class AudioRecorder: NSObject, ObservableObject {

    // MARK: - State
    @Published var isRecording = false

    // MARK: - Private
    private var scStream: SCStream?
    private var micEngine: AVAudioEngine?
    private var systemAudioBuffer: [Float] = []
    private var micBuffer: [Float] = []
    private let bufferLock = NSLock()
    private let sampleRate: Double = 16000
    private var startTime: Date?

    // MARK: - Public API

    func startRecording() async throws {
        guard !isRecording else { return }
        systemAudioBuffer = []
        micBuffer = []
        startTime = Date()

        try await startSystemAudioCapture()
        try startMicCapture()

        await MainActor.run { isRecording = true }
    }

    func stopRecording() async throws -> URL {
        guard isRecording else {
            throw RecorderError.notRecording
        }

        // Stop both streams
        scStream?.stopCapture()
        micEngine?.stop()
        scStream = nil
        micEngine = nil

        await MainActor.run { isRecording = false }

        // Mix and write WAV
        let wavURL = try mixAndWrite()
        return wavURL
    }

    // MARK: - System Audio (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                            onScreenWindowsOnly: false)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true

        // Capture all displays (= all system audio)
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.scStream = stream
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Convert to 16kHz mono
        guard let targetFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw RecorderError.formatError
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            // Convert to target format
            guard let converted = self.convertBuffer(buffer, from: inputFormat, to: targetFormat) else { return }
            let samples = self.toFloatArray(converted)
            self.bufferLock.lock()
            self.micBuffer.append(contentsOf: samples)
            self.bufferLock.unlock()
        }

        try engine.start()
        self.micEngine = engine
    }

    // MARK: - Mix and Write WAV

    private func mixAndWrite() throws -> URL {
        bufferLock.lock()
        let sys = systemAudioBuffer
        let mic = micBuffer
        bufferLock.unlock()

        // Pad shorter buffer to match lengths
        let length = max(sys.count, mic.count)
        var sysPadded = sys + [Float](repeating: 0, count: max(0, length - sys.count))
        var micPadded = mic + [Float](repeating: 0, count: max(0, length - mic.count))

        // Mix: average the two streams
        var mixed = [Float](repeating: 0, count: length)
        for i in 0..<length {
            mixed[i] = (sysPadded[i] + micPadded[i]) / 2.0
        }

        // Convert float [-1,1] to int16
        let int16Samples = mixed.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        // Write WAV
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-\(Int(Date().timeIntervalSince1970)).wav")
        try writeWAV(samples: int16Samples, sampleRate: Int(sampleRate), to: url)
        return url
    }

    // MARK: - WAV Writer

    private func writeWAV(samples: [Int16], sampleRate: Int, to url: URL) throws {
        var data = Data()

        let numSamples = samples.count
        let byteRate = sampleRate * 2  // 16-bit mono
        let dataSize = numSamples * 2

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.appendLittleEndian(UInt32(16))      // chunk size
        data.appendLittleEndian(UInt16(1))       // PCM
        data.appendLittleEndian(UInt16(1))       // mono
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(byteRate))
        data.appendLittleEndian(UInt16(2))       // block align
        data.appendLittleEndian(UInt16(16))      // bits per sample

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(UInt32(dataSize))
        for sample in samples {
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }

        try data.write(to: url)
    }

    // MARK: - Helpers

    private func convertBuffer(_ buffer: AVAudioPCMBuffer,
                                from: AVAudioFormat,
                                to: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: from, to: to) else { return nil }
        let ratio = to.sampleRate / from.sampleRate
        let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let output = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: outputFrames) else { return nil }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    private func toFloatArray(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}

// MARK: - SCStreamOutput (system audio callbacks)

extension AudioRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<CChar>? = nil
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard let ptr = dataPointer else { return }

        // Convert raw bytes (Float32) to [Float]
        let floatCount = length / MemoryLayout<Float>.size
        let samples = Array(UnsafeBufferPointer(
            start: UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: floatCount),
            count: floatCount
        ))
        bufferLock.lock()
        systemAudioBuffer.append(contentsOf: samples)
        bufferLock.unlock()
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case notRecording
    case noDisplay
    case formatError

    var errorDescription: String? {
        switch self {
        case .notRecording: return "Not currently recording"
        case .noDisplay:    return "No display found for audio capture"
        case .formatError:  return "Audio format conversion failed"
        }
    }
}

// MARK: - Data extension for WAV writing

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: MemoryLayout<T>.size))
    }
}
```

---

### `TranscribeClient.swift`

Swift HTTP client to call the Python server.

```swift
import Foundation

struct TranscribeClient {
    let baseURL = URL(string: "http://127.0.0.1:8765")!

    // POST /transcribe — send WAV file, receive transcript
    func transcribe(wavURL: URL, model: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("transcribe")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: wavURL))
        body.append("\r\n".data(using: .utf8)!)
        // model field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(model)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONDecoder().decode(TranscribeResponse.self, from: data)
        return json.transcript
    }

    // POST /summarise — send transcript, receive cleaned + summary
    func summarise(transcript: String, apiKey: String, model: String = "claude-sonnet-4-5") async throws -> SummariseResponse {
        let endpoint = baseURL.appendingPathComponent("summarise")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = SummariseRequest(transcript: transcript, api_key: apiKey, model: model)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(SummariseResponse.self, from: data)
    }
}

// MARK: - Codable types

struct TranscribeResponse: Decodable { let transcript: String }

struct SummariseRequest: Encodable {
    let transcript: String
    let api_key: String
    let model: String
}

struct SummariseResponse: Decodable {
    let cleaned_transcript: String
    let summary: String
}
```

---

### Temporary test button in `MenuBarView.swift`

Add this during development only (remove in Step 4 when hotkey is wired):

```swift
// Add to AppState:
let recorder = AudioRecorder()
let client = TranscribeClient()

// Temporary test action in MenuBarView:
Button("Test: Record 10s") {
    Task {
        do {
            try await appState.recorder.startRecording()
            try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            let wavURL = try await appState.recorder.stopRecording()
            print("WAV saved to: \(wavURL)")
            let transcript = try await appState.client.transcribe(
                wavURL: wavURL,
                model: "mlx-community/whisper-small-mlx"
            )
            print("Transcript: \(transcript)")
        } catch {
            print("Error: \(error)")
        }
    }
}
```

---

## Tests

### Test 1: Permission prompts
First run → macOS prompts for microphone and screen recording access. Grant both. ✅

### Test 2: Record and check WAV
```
1. Click "Test: Record 10s" in menu bar
2. Speak something + play a YouTube video
3. Wait 10 seconds
4. Check Xcode console for: "WAV saved to: /tmp/meeting-XXXXXX.wav"
5. Play it back: afplay /tmp/meeting-XXXXXX.wav
   → Should hear your voice + system audio mixed together
```

### Test 3: Transcription
After the WAV plays back correctly:
```
Check Xcode console for:
"Transcript: [what you said + what was playing]"
```

---

## Done When

- [ ] Microphone permission prompt appears on first run
- [ ] Screen recording permission prompt appears on first run
- [ ] "Test: Record 10s" records for 10s and saves a WAV
- [ ] `afplay <wav>` plays back both your voice and system audio
- [ ] Transcript appears in Xcode console after recording

---

**Next:** `plans/step-04-full-pipeline.md`
