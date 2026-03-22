import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

// AudioRecorder is NOT @MainActor so the IOProc callback (DispatchQueue)
// can safely touch sample buffers (protected by NSLock).
// Public API methods that set @Published state are individually @MainActor.
class AudioRecorder: NSObject, ObservableObject {

    // MARK: - State

    @Published var isRecording = false

    // MARK: - System audio (CoreAudio global process tap)

    private var tapID:             AudioObjectID        = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID: AudioDeviceID        = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID:          AudioDeviceIOProcID? = nil
    private var tapDescription:    CATapDescription?    = nil

    // MARK: - Microphone (AVAudioEngine)

    private var micEngine: AVAudioEngine?

    // MARK: - Sample buffers (lock-protected)

    /// Raw samples from the tap at tapSampleRate (mono).
    private var systemAudioSamples: [Float] = []
    /// Samples from mic already resampled to targetSampleRate.
    private var micSamples: [Float] = []
    private let lock = NSLock()

    /// Native sample rate reported by the tap (usually 44 100 or 48 000 Hz).
    private var tapSampleRate: Double = 48_000
    /// Rate Whisper expects.
    private let targetSampleRate: Double = 16_000

    // MARK: - Public API

    @MainActor
    func startRecording() async throws {
        guard !isRecording else { return }

        systemAudioSamples = []
        micSamples = []

        try startSystemAudioTap()
        try startMicCapture()

        isRecording = true
        print("AudioRecorder: recording started")
    }

    @MainActor
    func stopRecording() async throws -> URL {
        guard isRecording else { throw RecorderError.notRecording }

        stopSystemAudioTap()
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

    // MARK: - CoreAudio global mono tap (system audio, mute-independent)
    //
    // CATapDescription(monoGlobalTapButExcludeProcesses:) taps the entire
    // system audio output as a MONO stream, BEFORE the hardware volume/mute
    // stage — so recording continues even when the system is muted.
    // Apple's documentation explicitly states the tap is "independent of the
    // output device volume or mute state".
    //
    // This API triggers the "System Audio Recording Only" TCC permission —
    // the narrow bucket shown in System Settings → Privacy & Security, same
    // as Granola and ChatGPT.  (SCStream uses kTCCServiceScreenCapture and
    // lands in the wider "Screen & System Audio Recording" bucket instead.)

    private func startSystemAudioTap() throws {
        // 1. Global mono tap — captures all audio processes except our own.
        //    Passing an empty array means "exclude nothing extra", which is
        //    fine since our app produces no audio.
        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted   // speakers continue playing normally
        self.tapDescription = desc

        // 2. Register the tap.
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapErr == noErr else { throw RecorderError.tapError(tapErr) }
        self.tapID = tap

        // 3. Read native sample rate.
        tapSampleRate = readTapSampleRate(tapID: tap)

        // 4. Build a private aggregate device that presents the tap as an input.
        let sysOutID  = try defaultOutputDevice()
        let outputUID = try uid(for: sysOutID)
        let aggUID    = UUID().uuidString

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey:            "TranscribeMeetingTap",
            kAudioAggregateDeviceUIDKey:             aggUID,
            kAudioAggregateDeviceMainSubDeviceKey:   outputUID,
            kAudioAggregateDeviceIsPrivateKey:       true,
            kAudioAggregateDeviceIsStackedKey:       false,
            kAudioAggregateDeviceSubDeviceListKey:   [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey:               desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        var aggID = AudioDeviceID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard aggErr == noErr else { throw RecorderError.aggregateDeviceError(aggErr) }
        self.aggregateDeviceID = aggID

        // 5. IOProc receives PCM buffers from the aggregate device.
        let tapQueue = DispatchQueue(label: "transcribe.tap", qos: .userInitiated)
        var proc: AudioDeviceIOProcID? = nil
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, tapQueue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self else { return }

            let abl = inInputData.pointee
            guard abl.mNumberBuffers > 0 else { return }
            let buf = abl.mBuffers
            guard let rawPtr = buf.mData, buf.mDataByteSize > 0 else { return }

            let floatCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let floatPtr   = rawPtr.bindMemory(to: Float.self, capacity: floatCount)

            // Mono tap — one channel. If for any reason stereo arrives, average.
            let channels = Int(buf.mNumberChannels)
            if channels >= 2 {
                var mono = [Float]()
                mono.reserveCapacity(floatCount / channels)
                var i = 0
                while i + 1 < floatCount {
                    mono.append((floatPtr[i] + floatPtr[i + 1]) / 2.0)
                    i += channels
                }
                self.lock.lock()
                self.systemAudioSamples.append(contentsOf: mono)
                self.lock.unlock()
            } else {
                let samples = Array(UnsafeBufferPointer(start: floatPtr, count: floatCount))
                self.lock.lock()
                self.systemAudioSamples.append(contentsOf: samples)
                self.lock.unlock()
            }
        }
        guard procErr == noErr else { throw RecorderError.ioProcError(procErr) }
        self.ioProcID = proc

        // 6. Start the device.
        let startErr = AudioDeviceStart(aggID, proc)
        guard startErr == noErr else { throw RecorderError.deviceStartError(startErr) }

        print("AudioRecorder: CoreAudio global mono tap started (\(tapSampleRate) Hz)")
    }

    private func stopSystemAudioTap() {
        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            if let proc = ioProcID {
                AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        tapDescription = nil
    }

    // MARK: - CoreAudio helpers

    private func defaultOutputDevice() throws -> AudioDeviceID {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &prop, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != kAudioObjectUnknown else {
            throw RecorderError.noOutputDevice
        }
        return deviceID
    }

    private func uid(for deviceID: AudioDeviceID) throws -> String {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var cfUID: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(deviceID, &prop, 0, nil, &size, &cfUID)
        guard err == noErr, let uid = cfUID?.takeRetainedValue() else {
            throw RecorderError.noOutputDevice
        }
        return uid as String
    }

    private func readTapSampleRate(tapID: AudioObjectID) -> Double {
        var prop = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(tapID, &prop, 0, nil, &size, &asbd)
        return asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        let engine    = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFmt  = inputNode.outputFormat(forBus: 0)

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
        let rawSys = systemAudioSamples
        let mic    = micSamples
        lock.unlock()

        let sys    = resample(rawSys, from: tapSampleRate, to: targetSampleRate)
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

    // MARK: - Linear resampler

    private func resample(_ input: [Float], from: Double, to: Double) -> [Float] {
        guard from != to, !input.isEmpty else { return input }
        let ratio    = to / from
        let outCount = Int(Double(input.count) * ratio)
        var output   = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let srcPos = Double(i) / ratio
            let lo     = Int(srcPos)
            let hi     = min(lo + 1, input.count - 1)
            let frac   = Float(srcPos - Double(lo))
            output[i]  = input[lo] * (1 - frac) + input[hi] * frac
        }
        return output
    }

    // MARK: - WAV writer

    private func writeWAV(samples: [Int16], sampleRate: Int, to url: URL) throws {
        var data = Data()
        let dataSize = samples.count * 2
        let byteRate = sampleRate * 2

        data.appendString("RIFF")
        data.appendUInt32(UInt32(36 + dataSize))
        data.appendString("WAVE")
        data.appendString("fmt ")
        data.appendUInt32(16)
        data.appendUInt16(1)
        data.appendUInt16(1)
        data.appendUInt32(UInt32(sampleRate))
        data.appendUInt32(UInt32(byteRate))
        data.appendUInt16(2)
        data.appendUInt16(16)
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

// MARK: - Errors

enum RecorderError: LocalizedError {
    case notRecording
    case noOutputDevice
    case tapError(OSStatus)
    case aggregateDeviceError(OSStatus)
    case ioProcError(OSStatus)
    case deviceStartError(OSStatus)
    case formatError
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .notRecording:                return "Not currently recording"
        case .noOutputDevice:              return "No audio output device found"
        case .tapError(let s):             return "CoreAudio tap creation failed (OSStatus \(s))"
        case .aggregateDeviceError(let s): return "Aggregate device creation failed (OSStatus \(s))"
        case .ioProcError(let s):          return "IOProc creation failed (OSStatus \(s))"
        case .deviceStartError(let s):     return "Device start failed (OSStatus \(s))"
        case .formatError:                 return "Audio format conversion failed"
        case .noAudioCaptured:             return "No audio was captured"
        }
    }
}

// MARK: - Data WAV helpers

private extension Data {
    mutating func appendString(_ s: String) { append(contentsOf: s.utf8) }
    mutating func appendUInt16(_ v: UInt16) { var x = v.littleEndian; append(Data(bytes: &x, count: 2)) }
    mutating func appendUInt32(_ v: UInt32) { var x = v.littleEndian; append(Data(bytes: &x, count: 4)) }
}
