import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

// AudioRecorder captures system audio via CATapDescription (macOS 14.2+) and
// microphone via AVAudioEngine.
//
// CATap taps process audio BEFORE the hardware volume/mute stage, so audio is
// captured even when the system is muted. privateTap + private aggregate device
// keep the tap invisible system-wide (no screen-recording indicator).
// The permission prompt is "System Audio Recording Only" (kTCCServiceAudioCapture),
// not screen recording.
class AudioRecorder: NSObject, ObservableObject {

    // MARK: - State

    @Published var isRecording = false
    /// Normalised microphone RMS level, 0…1. Updated on the main thread ~20× per second.
    @Published var micLevel: Float = 0

    // MARK: - System audio (CATap + aggregate device)

    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var tapIOProcID: AudioDeviceIOProcID? = nil
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var pendingOutputDeviceListenerInstall: DispatchWorkItem?
    private var systemRestartWorkItem: DispatchWorkItem?
    private var isRestartingSystemAudio = false
    private var ignoreOutputDeviceChangesUntil = Date.distantPast

    // MARK: - Microphone (AVAudioEngine)

    private var micEngine: AVAudioEngine?
    /// Token returned by the closure-based NotificationCenter API — must be
    /// stored and used to unregister, because removeObserver(_:name:object:)
    /// does NOT work with the closure-based registration.
    private var configChangeObserver: (any NSObjectProtocol)?
    /// macOS can briefly report an invalid input hardware format while the CATap
    /// aggregate device is being created or torn down. Use this timestamp to
    /// suppress AVAudioEngine restart churn during that settling window.
    private var lastMicStartDate: Date = .distantPast
    private var micRestartWorkItem: DispatchWorkItem?
    private var isRestartingMicCapture = false

    // MARK: - Sample buffers (lock-protected)

    private var systemAudioSamples: [Float] = []
    private var micSamples: [Float] = []
    private let lock = NSLock()

    private var tapSampleRate: Double = 48_000
    private let targetSampleRate: Double = 16_000

    // MARK: - Public API

    @MainActor
    func startRecording(captureSystemAudio: Bool = true) async throws {
        guard !isRecording else { return }

        systemAudioSamples = []
        micSamples = []
        do {
            if captureSystemAudio {
                try startSystemAudioCapture()
            }
            try startMicCapture()
            isRecording = true
            let modeLabel = captureSystemAudio ? "mic + system audio" : "mic only"
            print("AudioRecorder: recording started (\(modeLabel))")
        } catch {
            stopSystemAudioCapture()
            stopMicCapture()
            isRecording = false
            throw error
        }
    }

    @MainActor
    func stopRecording() async throws -> URL {
        guard isRecording else { throw RecorderError.notRecording }

        stopSystemAudioCapture()
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

    // MARK: - System audio (CATap)

    private func startSystemAudioCapture() throws {
        // 1. Describe the tap: global mono mix, tap before mute stage, private.
        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        tapDesc.name = "TranscribeMeetingsTap"
        tapDesc.muteBehavior = .unmuted   // capture even when system volume = 0
        tapDesc.isPrivate = true          // invisible outside this process

        // 2. Create the process tap — triggers "System Audio Recording" permission dialog.
        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
        guard tapStatus == noErr else {
            throw RecorderError.tapCreationFailed(tapStatus)
        }
        tapObjectID = tapID

        // 3. Wrap in a private aggregate device so we can attach an IOProc.
        //    "private": 1 is required when the tap is private — otherwise AudioDeviceStart
        //    returns kAudioHardwareIllegalOperationError ('nope').
        let tapUID = tapDesc.uuid.uuidString
        let aggUID = "TranscribeMeetings-\(UUID().uuidString)"
        let aggDict: [String: Any] = [
            "name": "TranscribeMeetingsAggDevice",
            "uid":  aggUID,
            "private": 1,
            "taps": [["uid": tapUID, "drift": 1]]
        ]
        var aggID: AudioDeviceID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapObjectID = kAudioObjectUnknown
            throw RecorderError.aggregateDeviceCreationFailed(aggStatus)
        }
        aggregateDeviceID = aggID

        // 4. Read the sample rate the aggregate device delivers.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Float64>.size)
        var sr: Float64 = 48_000
        AudioObjectGetPropertyData(aggID, &addr, 0, nil, &size, &sr)
        tapSampleRate = sr

        // 5. Register IOProc to receive audio from the aggregate device.
        var procID: AudioDeviceIOProcID? = nil
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleTapAudio(inInputData)
        }
        guard procStatus == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            aggregateDeviceID = kAudioObjectUnknown
            tapObjectID = kAudioObjectUnknown
            throw RecorderError.ioProcCreationFailed(procStatus)
        }
        tapIOProcID = procID

        // 6. Start — audio begins flowing into the IOProc.
        let startStatus = AudioDeviceStart(aggID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggID, procID)
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            tapIOProcID = nil
            aggregateDeviceID = kAudioObjectUnknown
            tapObjectID = kAudioObjectUnknown
            throw RecorderError.audioDeviceStartFailed(startStatus)
        }

        ignoreOutputDeviceChangesUntil = Date().addingTimeInterval(2.0)
        print("AudioRecorder: CATap capture started (sr=\(sr)Hz)")
        // Creating the private aggregate device itself can briefly perturb the
        // HAL graph. Delay listener installation so we do not immediately react
        // to our own setup work and enter a restart loop.
        scheduleOutputDeviceListenerInstall()
    }

    private func installOutputDeviceListener() {
        guard deviceChangeListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRecording else { return }
            guard Date() >= self.ignoreOutputDeviceChangesUntil else { return }
            // Output device changed (e.g. headphones connected) — restart the tap
            // so the aggregate device wraps the new device's audio graph.
            self.scheduleSystemAudioRestart()
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        deviceChangeListener = block
    }

    private func scheduleOutputDeviceListenerInstall() {
        pendingOutputDeviceListenerInstall?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording || self.tapObjectID != kAudioObjectUnknown else { return }
            self.installOutputDeviceListener()
        }
        pendingOutputDeviceListenerInstall = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func removeOutputDeviceListener() {
        pendingOutputDeviceListenerInstall?.cancel()
        pendingOutputDeviceListenerInstall = nil
        guard let block = deviceChangeListener else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        deviceChangeListener = nil
    }

    private func scheduleSystemAudioRestart() {
        systemRestartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.restartSystemAudioCapture()
        }
        systemRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    /// Called on the main thread when the default output device changes during recording.
    private func restartSystemAudioCapture() {
        guard !isRestartingSystemAudio else { return }
        isRestartingSystemAudio = true
        defer { isRestartingSystemAudio = false }
        // Remove listener first so we don't recurse during teardown.
        removeOutputDeviceListener()
        stopSystemAudioCaptureObjects()
        lock.lock()
        systemAudioSamples = []
        lock.unlock()
        try? startSystemAudioCapture()
    }

    private func stopSystemAudioCapture() {
        systemRestartWorkItem?.cancel()
        systemRestartWorkItem = nil
        removeOutputDeviceListener()
        stopSystemAudioCaptureObjects()
    }

    private func stopSystemAudioCaptureObjects() {
        if let procID = tapIOProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            tapIOProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapObjectID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = kAudioObjectUnknown
        }
    }

    private func handleTapAudio(_ inputData: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        var samples = [Float]()
        for buf in abl {
            guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let ptr   = data.bindMemory(to: Float.self, capacity: count)
            let ch    = Int(buf.mNumberChannels)
            if ch >= 2 {
                var i = 0
                while i + 1 < count {
                    samples.append((ptr[i] + ptr[i + 1]) / 2.0)
                    i += ch
                }
            } else {
                samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: count))
            }
        }
        guard !samples.isEmpty else { return }
        lock.lock()
        systemAudioSamples.append(contentsOf: samples)
        lock.unlock()
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMicCapture() throws {
        lastMicStartDate = Date()
        let engine    = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFmt  = inputNode.outputFormat(forBus: 0)
        guard inputFmt.sampleRate > 0, inputFmt.channelCount > 0 else {
            throw RecorderError.invalidInputHardwareFormat
        }

        guard let targetFmt = AVAudioFormat(
            standardFormatWithSampleRate: targetSampleRate, channels: 1
        ) else { throw RecorderError.formatError }

        // Do not force a potentially stale hardware format back into the engine.
        // Let AVAudioEngine use the current bus format and convert from each buffer's
        // actual format instead. This avoids the "Input HW format is invalid" crash
        // during transient route churn.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) {
            [weak self] buffer, _ in
            guard let self else { return }

            // Compute RMS and publish as micLevel for the waveform indicator.
            if let ch = buffer.floatChannelData {
                let frames = Int(buffer.frameLength)
                let ptr = ch[0]
                var sum: Float = 0
                for i in 0..<frames { sum += ptr[i] * ptr[i] }
                let rms = frames > 0 ? sqrt(sum / Float(frames)) : 0
                // Scale: typical speech RMS ~0.02–0.1 → map to 0…1 with a 40× gain.
                let normalised = min(1.0, rms * 40)
                DispatchQueue.main.async { self.micLevel = normalised }
            }

            let sourceFormat = buffer.format
            guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else { return }
            let samples = self.convertAndExtract(buffer, from: sourceFormat, to: targetFmt)
            self.lock.lock()
            self.micSamples.append(contentsOf: samples)
            self.lock.unlock()
        }

        // When headphones with a mic are connected/disconnected, AVAudioEngine posts
        // AVAudioEngineConfigurationChange — the engine must be restarted.
        // Store the token so we can properly remove this observer later.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            // Ignore notifications emitted by the graph churn we cause ourselves
            // while CATap + aggregate device creation is still settling.
            guard Date().timeIntervalSince(self.lastMicStartDate) > 2.0 else { return }
            self.scheduleMicCaptureRestart()
        }

        try engine.start()
        self.micEngine = engine
        print("AudioRecorder: microphone capture started")
    }

    private func scheduleMicCaptureRestart() {
        micRestartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.restartMicCapture()
        }
        micRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func restartMicCapture() {
        guard isRecording, !isRestartingMicCapture else { return }
        isRestartingMicCapture = true
        defer { isRestartingMicCapture = false }

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
            configChangeObserver = nil
        }

        do {
            try startMicCapture()
        } catch {
            print("AudioRecorder: mic restart failed after config change: \(error)")
        }
    }

    private func stopMicCapture() {
        micRestartWorkItem?.cancel()
        micRestartWorkItem = nil
        isRestartingMicCapture = false
        if let token = configChangeObserver {
            NotificationCenter.default.removeObserver(token)
            configChangeObserver = nil
        }
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        DispatchQueue.main.async { self.micLevel = 0 }
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
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case audioDeviceStartFailed(OSStatus)
    case invalidInputHardwareFormat
    case formatError
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .notRecording:                          return "Not currently recording"
        case .tapCreationFailed(let s):              return "Failed to create audio tap (err \(s))"
        case .aggregateDeviceCreationFailed(let s):  return "Failed to create aggregate device (err \(s))"
        case .ioProcCreationFailed(let s):           return "Failed to create IOProc (err \(s))"
        case .audioDeviceStartFailed(let s):         return "Failed to start audio device (err \(s))"
        case .invalidInputHardwareFormat:            return "Microphone hardware format was temporarily invalid"
        case .formatError:                           return "Audio format conversion failed"
        case .noAudioCaptured:                       return "No audio was captured"
        }
    }
}

// MARK: - Data WAV helpers

private extension Data {
    mutating func appendString(_ s: String) { append(contentsOf: s.utf8) }
    mutating func appendUInt16(_ v: UInt16) { var x = v.littleEndian; append(Data(bytes: &x, count: 2)) }
    mutating func appendUInt32(_ v: UInt32) { var x = v.littleEndian; append(Data(bytes: &x, count: 4)) }
}
