import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

struct RecordingInputDevice: Sendable {
    let uniqueID: String
    let name: String
    let transportType: UInt32?
    let transportLabel: String
    let isBluetooth: Bool
}

struct RecordingResult: Sendable {
    let wavURL: URL
    let capturedSampleCount16k: Int
    let writtenSampleCount16k: Int
    let durationSeconds: Double
    let inputDeviceName: String
    let isBluetoothInput: Bool
    let wasPaddedForASR: Bool
}

private enum MicCapturePolicy {
    case standard
    case bluetooth
}

// AudioRecorder captures system audio via CATapDescription (macOS 14.2+) and
// microphone via AVCaptureSession.
//
// CATap taps process audio BEFORE the hardware volume/mute stage, so audio is
// captured even when the system is muted. privateTap + private aggregate device
// keep the tap invisible system-wide (no screen-recording indicator).
// The permission prompt is "System Audio Recording Only" (kTCCServiceAudioCapture),
// not screen recording.
class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    var onRecordingReady: (() -> Void)?

    // MARK: - State

    @Published var isRecording = false
    /// Normalised microphone RMS level, 0…1. Updated on the main thread ~20× per second.
    @Published var micLevel: Float = 0
    /// Flips to true on the main thread once the first audio buffer arrives from the mic tap.
    @Published var isMicActive = false

    // MARK: - System audio (CATap + aggregate device)

    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var tapIOProcID: AudioDeviceIOProcID? = nil
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var pendingOutputDeviceListenerInstall: DispatchWorkItem?
    private var systemRestartWorkItem: DispatchWorkItem?
    private var isRestartingSystemAudio = false
    private var ignoreOutputDeviceChangesUntil = Date.distantPast

    // MARK: - Microphone (AVCaptureSession)

    private var micCaptureSession: AVCaptureSession?
    private var micCaptureInput: AVCaptureDeviceInput?
    private var micCaptureOutput: AVCaptureAudioDataOutput?
    private let micCaptureQueue = DispatchQueue(label: "Whale.AudioRecorder.MicCapture")
    private var inputDeviceChangeListener: AudioObjectPropertyListenerBlock?
    private var captureDeviceDisconnectObserver: (any NSObjectProtocol)?
    /// macOS can briefly report an invalid input hardware format while the CATap
    /// aggregate device is being created or torn down. Use this timestamp to
    /// suppress restart churn during that settling window.
    private var lastMicStartDate: Date = .distantPast
    private var micRestartWorkItem: DispatchWorkItem?
    private var isRestartingMicCapture = false
    private var currentInputDeviceUniqueID: String?
    private var currentInputDevice: RecordingInputDevice?
    private var micCapturePolicy: MicCapturePolicy = .standard
    private let micReadyLock = NSLock()
    private var hasReceivedUsableMicBuffer = false
    private var isAwaitingBluetoothStabilization = false
    private var bluetoothStableBufferCount = 0
    private var bluetoothRestartCount = 0
    private var lastBluetoothConfigChangeAt: Date?
    private var lastUsableBluetoothBufferAt: Date?

    // MARK: - Mic level indicator (decay-smoothed)

    private var lastMicLevelUpdate: Date = .distantPast
    private var micLevelDecayTimer: DispatchSourceTimer?
    private let micLevelDecayInterval: TimeInterval = 0.05
    private let micLevelStalenessThreshold: TimeInterval = 0.15
    private let micLevelDecayFactor: Float = 0.55

    // MARK: - Sample buffers (lock-protected)

    private var systemAudioSamples: [Float] = []
    private var micSamples: [Float] = []
    private let lock = NSLock()

    private var tapSampleRate: Double = 48_000
    private let targetSampleRate: Double = 16_000
    private let minimumASRSamples = 16_000
    private var currentCaptureIncludesSystemAudio = true
    private let bluetoothReadyBufferTarget = 3
    private let bluetoothRestartDelay: TimeInterval = 0.2
    private let bluetoothReadyQuietPeriod: TimeInterval = 0.25
    private let bluetoothFallbackRestartDelay: TimeInterval = 0.75
    private var bluetoothStartupValidationWorkItem: DispatchWorkItem?

    // MARK: - Public API

    func activeInputDevice() throws -> RecordingInputDevice {
        if let currentInputDevice {
            return currentInputDevice
        }
        return try currentDefaultInputDevice()
    }

    @MainActor
    func startRecording(captureSystemAudio: Bool = true) async throws {
        guard !isRecording else { return }

        currentCaptureIncludesSystemAudio = captureSystemAudio
        systemAudioSamples = []
        micSamples = []
        do {
            if captureSystemAudio {
                try startSystemAudioCapture()
            }
            try startMicCapture()
            startMicLevelDecay()
            isRecording = true
            let modeLabel = captureSystemAudio ? "mic + system audio" : "mic only"
            print("AudioRecorder: engine started (\(modeLabel))")
        } catch {
            stopSystemAudioCapture()
            await stopMicCapture()
            stopMicLevelDecay()
            isRecording = false
            throw error
        }
    }

    @MainActor
    func stopRecording() async throws -> RecordingResult {
        guard isRecording else { throw RecorderError.notRecording }

        stopSystemAudioCapture()
        await stopMicCapture()
        stopMicLevelDecay()
        micLevel = 0
        isMicActive = false

        isRecording = false
        print("AudioRecorder: recording stopped")

        return try mixAndWriteWAV()
    }

    // MARK: - Mic level decay timer

    private func startMicLevelDecay() {
        stopMicLevelDecay()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + micLevelDecayInterval,
                       repeating: micLevelDecayInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.lastMicLevelUpdate)
            guard elapsed > self.micLevelStalenessThreshold else { return }
            let decayed = self.micLevel * self.micLevelDecayFactor
            self.micLevel = decayed < 0.01 ? 0 : decayed
        }
        timer.resume()
        micLevelDecayTimer = timer
    }

    private func stopMicLevelDecay() {
        micLevelDecayTimer?.cancel()
        micLevelDecayTimer = nil
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

    // MARK: - Microphone (AVCaptureSession)

    private func startMicCapture() throws {
        lastMicStartDate = Date()
        let inputDevice = try currentDefaultInputDevice()
        let capturePolicy: MicCapturePolicy =
            !currentCaptureIncludesSystemAudio && inputDevice.isBluetooth ? .bluetooth : .standard
        guard let captureDevice = captureDevice(for: inputDevice.uniqueID) else {
            throw RecorderError.inputDeviceUnavailable("Selected microphone is no longer available")
        }
        let session = AVCaptureSession()
        session.beginConfiguration()

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: captureDevice)
        } catch {
            throw RecorderError.captureSessionSetupFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            throw RecorderError.captureSessionSetupFailed("Unable to attach the selected microphone input")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: micCaptureQueue)
        guard session.canAddOutput(output) else {
            throw RecorderError.captureSessionSetupFailed("Unable to attach the microphone output")
        }
        session.addOutput(output)
        session.commitConfiguration()

        currentInputDevice = inputDevice
        currentInputDeviceUniqueID = inputDevice.uniqueID
        micCapturePolicy = capturePolicy
        beginMicReadyState(for: capturePolicy, preserveRestartCount: isRestartingMicCapture)

        micCaptureSession = session
        micCaptureInput = input
        micCaptureOutput = output
        installInputDeviceListener()
        installCaptureDeviceDisconnectObserver()
        session.startRunning()
        if capturePolicy == .bluetooth {
            scheduleBluetoothStartupValidation(after: bluetoothFallbackRestartDelay)
        }
        print(
            "AudioRecorder: microphone capture started (device=\(inputDevice.name), " +
            "transport=\(inputDevice.transportLabel), bluetooth=\(inputDevice.isBluetooth), " +
            "policy=\(capturePolicyLabel(capturePolicy)), " +
            "sr=\(Int(targetSampleRate))Hz, ch=1)"
        )
    }

    private func scheduleMicCaptureRestart(after delay: TimeInterval) {
        micRestartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.restartMicCapture()
        }
        micRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func restartMicCapture() {
        guard isRecording, !isRestartingMicCapture else { return }
        isRestartingMicCapture = true
        defer { isRestartingMicCapture = false }
        if micCapturePolicy == .bluetooth {
            micReadyLock.lock()
            bluetoothRestartCount += 1
            isAwaitingBluetoothStabilization = true
            bluetoothStableBufferCount = 0
            lastBluetoothConfigChangeAt = Date()
            micReadyLock.unlock()
            print("AudioRecorder: restarting bluetooth mic capture (\(bluetoothRestartCount))")
        }

        teardownMicCapture()

        do {
            try startMicCapture()
        } catch {
            print("AudioRecorder: mic restart failed after config change: \(error)")
        }
    }

    private func stopMicCapture() async {
        micRestartWorkItem?.cancel()
        micRestartWorkItem = nil
        bluetoothStartupValidationWorkItem?.cancel()
        bluetoothStartupValidationWorkItem = nil
        isRestartingMicCapture = false
        teardownMicCapture()
        await drainPendingMicCaptureCallbacks()
    }

    private func teardownMicCapture() {
        removeInputDeviceListener()
        if let token = captureDeviceDisconnectObserver {
            NotificationCenter.default.removeObserver(token)
            captureDeviceDisconnectObserver = nil
        }
        micCaptureSession?.stopRunning()
        micCaptureOutput?.setSampleBufferDelegate(nil, queue: nil)
        micCaptureOutput = nil
        micCaptureInput = nil
        micCaptureSession = nil
        currentInputDeviceUniqueID = nil
        clearMicReadyState()
    }

    private func drainPendingMicCaptureCallbacks() async {
        await withCheckedContinuation { continuation in
            micCaptureQueue.async {
                continuation.resume()
            }
        }
    }

    private func handleUsableMicSamples() {
        if micCapturePolicy == .bluetooth {
            handleBluetoothUsableBuffer()
            return
        }
        let shouldPromote: Bool
        micReadyLock.lock()
        if hasReceivedUsableMicBuffer {
            shouldPromote = false
        } else {
            hasReceivedUsableMicBuffer = true
            shouldPromote = true
        }
        micReadyLock.unlock()
        guard shouldPromote else { return }
        print("AudioRecorder: first usable mic buffer received")
        print("AudioRecorder: recording promoted to ready")
        Task { @MainActor [weak self] in
            self?.onRecordingReady?()
        }
    }

    private func beginMicReadyState(for policy: MicCapturePolicy, preserveRestartCount: Bool) {
        micReadyLock.lock()
        hasReceivedUsableMicBuffer = false
        isAwaitingBluetoothStabilization = policy == .bluetooth
        bluetoothStableBufferCount = 0
        if !preserveRestartCount {
            bluetoothRestartCount = 0
        }
        lastBluetoothConfigChangeAt = nil
        lastUsableBluetoothBufferAt = nil
        micReadyLock.unlock()
    }

    private func clearMicReadyState() {
        micReadyLock.lock()
        hasReceivedUsableMicBuffer = false
        isAwaitingBluetoothStabilization = false
        bluetoothStableBufferCount = 0
        lastBluetoothConfigChangeAt = nil
        lastUsableBluetoothBufferAt = nil
        micReadyLock.unlock()
    }

    private func installInputDeviceListener() {
        guard inputDeviceChangeListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isRecording else { return }
            let nextInputUniqueID = try? self.currentDefaultInputDevice().uniqueID
            guard nextInputUniqueID != self.currentInputDeviceUniqueID else { return }
            let delay = self.micCapturePolicy == .bluetooth ? self.bluetoothRestartDelay : 1.0
            self.scheduleMicCaptureRestart(after: delay)
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
        inputDeviceChangeListener = block
    }

    private func removeInputDeviceListener() {
        guard let block = inputDeviceChangeListener else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
        inputDeviceChangeListener = nil
    }

    private func handleBluetoothUsableBuffer() {
        let now = Date()
        let shouldPromote: Bool
        let stableBufferCount: Int
        micReadyLock.lock()
        lastUsableBluetoothBufferAt = now
        if hasReceivedUsableMicBuffer {
            shouldPromote = false
            stableBufferCount = bluetoothStableBufferCount
        } else {
            bluetoothStableBufferCount += 1
            stableBufferCount = bluetoothStableBufferCount
            let quietSinceConfigChange: Bool
            if let lastBluetoothConfigChangeAt {
                quietSinceConfigChange =
                    now.timeIntervalSince(lastBluetoothConfigChangeAt) >= bluetoothReadyQuietPeriod
            } else {
                quietSinceConfigChange =
                    now.timeIntervalSince(lastMicStartDate) >= bluetoothReadyQuietPeriod
            }
            shouldPromote = quietSinceConfigChange && bluetoothStableBufferCount >= bluetoothReadyBufferTarget
            if shouldPromote {
                hasReceivedUsableMicBuffer = true
                isAwaitingBluetoothStabilization = false
            }
        }
        micReadyLock.unlock()
        if stableBufferCount == 1 {
            print("AudioRecorder: first usable bluetooth mic buffer received")
        }
        bluetoothStartupValidationWorkItem?.cancel()
        bluetoothStartupValidationWorkItem = nil
        guard shouldPromote else { return }
        print(
            "AudioRecorder: bluetooth recording promoted to ready " +
            "(buffers=\(stableBufferCount), restarts=\(bluetoothRestartCount))"
        )
        Task { @MainActor [weak self] in
            self?.onRecordingReady?()
        }
    }

    private func capturePolicyLabel(_ policy: MicCapturePolicy) -> String {
        switch policy {
        case .standard:
            return "standard"
        case .bluetooth:
            return "bluetooth"
        }
    }

    private func scheduleBluetoothStartupValidation(after delay: TimeInterval) {
        bluetoothStartupValidationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.validateBluetoothStartup()
        }
        bluetoothStartupValidationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func validateBluetoothStartup() {
        guard isRecording, micCapturePolicy == .bluetooth else { return }
        let shouldRestart: Bool
        micReadyLock.lock()
        shouldRestart = !hasReceivedUsableMicBuffer && isAwaitingBluetoothStabilization
        micReadyLock.unlock()
        guard shouldRestart else { return }
        print("AudioRecorder: bluetooth route did not settle in time; restarting capture")
        scheduleMicCaptureRestart(after: bluetoothRestartDelay)
    }

    private func installCaptureDeviceDisconnectObserver() {
        guard captureDeviceDisconnectObserver == nil else { return }
        captureDeviceDisconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.isRecording else { return }
            guard let device = notification.object as? AVCaptureDevice else { return }
            guard device.uniqueID == self.currentInputDeviceUniqueID else { return }
            print("AudioRecorder: selected microphone disconnected; restarting capture")
            self.scheduleMicCaptureRestart(after: 0.1)
        }
    }

    private func currentDefaultInputDevice() throws -> RecordingInputDevice {
        guard let defaultDevice = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified)
            ?? AVCaptureDevice.default(for: .audio)
        else {
            throw RecorderError.inputDeviceUnavailable("No microphone is available for capture")
        }
        let defaultInput = recordingInputDevice(for: defaultDevice)
        let isBluetooth = defaultInput.isBluetooth
        if isBluetooth, let builtIn = builtInInputDevice() {
            print(
                "AudioRecorder: default input is bluetooth (\(defaultInput.name)); " +
                "falling back to built-in (\(builtIn.name))"
            )
            return builtIn
        }
        return defaultInput
    }

    private func builtInInputDevice() -> RecordingInputDevice? {
        availableInputDevices()
            .first { isBuiltInTransport(UInt32(bitPattern: $0.transportType)) }
            .map(recordingInputDevice(for:))
    }

    private func availableInputDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    private func captureDevice(for uniqueID: String) -> AVCaptureDevice? {
        availableInputDevices().first { $0.uniqueID == uniqueID }
    }

    private func recordingInputDevice(for captureDevice: AVCaptureDevice) -> RecordingInputDevice {
        let transportType = UInt32(bitPattern: captureDevice.transportType)
        let name = captureDevice.localizedName
        return RecordingInputDevice(
            uniqueID: captureDevice.uniqueID,
            name: name,
            transportType: transportType,
            transportLabel: transportLabel(for: transportType),
            isBluetooth: isBluetoothTransport(transportType) || inferredBluetoothDeviceName(name)
        )
    }

    private func isBluetoothTransport(_ transportType: UInt32?) -> Bool {
        guard let transportType else { return false }
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    private func isBuiltInTransport(_ transportType: UInt32?) -> Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }

    private func transportLabel(for transportType: UInt32?) -> String {
        guard let transportType else { return "unknown" }
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "built-in"
        case kAudioDeviceTransportTypeBluetooth:
            return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "bluetooth-le"
        case kAudioDeviceTransportTypeUSB:
            return "usb"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay"
        case kAudioDeviceTransportTypeAggregate:
            return "aggregate"
        default:
            return fourCharCodeString(transportType)
        }
    }

    private func inferredBluetoothDeviceName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let bluetoothMarkers = ["airpods", "buds", "beats", "bluetooth", "headset"]
        return bluetoothMarkers.contains { lowered.contains($0) }
    }

    private func fourCharCodeString(_ value: UInt32) -> String {
        let scalarBytes: [UnicodeScalar] = [
            UnicodeScalar((value >> 24) & 0xFF),
            UnicodeScalar((value >> 16) & 0xFF),
            UnicodeScalar((value >> 8) & 0xFF),
            UnicodeScalar(value & 0xFF),
        ].compactMap { $0 }
        let string = String(String.UnicodeScalarView(scalarBytes))
        return string.trimmingCharacters(in: .controlCharacters)
    }

    // MARK: - Mix + Write WAV

    private func mixAndWriteWAV() throws -> RecordingResult {
        lock.lock()
        let rawSys = systemAudioSamples
        let mic    = micSamples
        lock.unlock()

        let sys = resample(rawSys, from: tapSampleRate, to: targetSampleRate)
        let capturedLength = max(sys.count, mic.count)
        guard capturedLength > 0 else { throw RecorderError.noAudioCaptured }

        let sysPad = sys + [Float](repeating: 0, count: max(0, capturedLength - sys.count))
        let micPad = mic + [Float](repeating: 0, count: max(0, capturedLength - mic.count))

        var mixed = [Float](repeating: 0, count: capturedLength)
        for i in 0..<capturedLength {
            mixed[i] = (sysPad[i] + micPad[i]) / 2.0
        }

        let shouldPadForASR = !currentCaptureIncludesSystemAudio && mixed.count < minimumASRSamples
        if shouldPadForASR {
            mixed.append(contentsOf: [Float](repeating: 0, count: minimumASRSamples - mixed.count))
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
        let inputDevice = currentInputDevice
        let inputDeviceName = inputDevice?.name ?? "Unknown Input"
        let capturedDuration = Double(capturedLength) / targetSampleRate
        print(
            "AudioRecorder: WAV saved → \(url.lastPathComponent) (\(kb / 1024) KB, " +
            "captured=\(capturedLength) samples, written=\(mixed.count) samples, " +
            "padded=\(shouldPadForASR), device=\(inputDeviceName))"
        )
        let result = RecordingResult(
            wavURL: url,
            capturedSampleCount16k: capturedLength,
            writtenSampleCount16k: mixed.count,
            durationSeconds: capturedDuration,
            inputDeviceName: inputDeviceName,
            isBluetoothInput: inputDevice?.isBluetooth ?? false,
            wasPaddedForASR: shouldPadForASR
        )
        currentInputDevice = nil
        return result
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

    // MARK: - Audio sample extraction (mic capture → 16 kHz mono)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecording else { return }
        let samples = extractMicSamples(from: sampleBuffer)
        guard !samples.isEmpty else { return }
        updateMicLevel(using: samples)
        lock.lock()
        micSamples.append(contentsOf: samples)
        lock.unlock()
        handleUsableMicSamples()
    }

    private func updateMicLevel(using samples: [Float]) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(samples.count))
        let normalised = min(1.0, rms * 40)
        DispatchQueue.main.async {
            self.lastMicLevelUpdate = Date()
            self.micLevel = max(normalised, self.micLevel * 0.7)
            if !self.isMicActive { self.isMicActive = true }
        }
    }

    private func extractMicSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return [] }

        let asbd = streamBasicDescription.pointee
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return [] }
        guard (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 else {
            print("AudioRecorder: unsupported non-interleaved microphone sample buffer")
            return []
        }

        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        guard bytesPerFrame > 0 else {
            print("AudioRecorder: unsupported microphone sample buffer with zero bytes per frame")
            return []
        }

        var rawData = Data(count: frameCount * bytesPerFrame)
        let copyStatus = rawData.withUnsafeMutableBytes { rawBytes -> OSStatus in
            guard let baseAddress = rawBytes.baseAddress else { return OSStatus(paramErr) }
            var audioBufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: asbd.mChannelsPerFrame,
                    mDataByteSize: UInt32(rawBytes.count),
                    mData: baseAddress
                )
            )
            return CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sampleBuffer,
                at: 0,
                frameCount: Int32(frameCount),
                into: &audioBufferList
            )
        }
        guard copyStatus == noErr else {
            print("AudioRecorder: failed to copy microphone sample buffer (err \(copyStatus))")
            return []
        }

        let extracted: [Float]
        if (asbd.mFormatFlags & kLinearPCMFormatFlagIsFloat) != 0, asbd.mBitsPerChannel == 32 {
            extracted = decodeFloatSamples(from: rawData, frameCount: frameCount, channels: channels)
        } else if (asbd.mFormatFlags & kLinearPCMFormatFlagIsSignedInteger) != 0,
                  asbd.mBitsPerChannel == 16 {
            extracted = decodeInt16Samples(from: rawData, frameCount: frameCount, channels: channels)
        } else {
            print(
                "AudioRecorder: unsupported microphone PCM format " +
                "(bits=\(asbd.mBitsPerChannel), flags=\(asbd.mFormatFlags))"
            )
            return []
        }

        guard asbd.mSampleRate > 0 else { return extracted }
        if asbd.mSampleRate != targetSampleRate {
            return resample(extracted, from: asbd.mSampleRate, to: targetSampleRate)
        }
        return extracted
    }

    private func decodeFloatSamples(from rawData: Data, frameCount: Int, channels: Int) -> [Float] {
        rawData.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Float.self)
            if channels == 1 {
                return Array(values.prefix(frameCount))
            }
            var mixed = [Float]()
            mixed.reserveCapacity(frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                let baseIndex = frame * channels
                for channel in 0..<channels {
                    sum += values[baseIndex + channel]
                }
                mixed.append(sum / Float(channels))
            }
            return mixed
        }
    }

    private func decodeInt16Samples(from rawData: Data, frameCount: Int, channels: Int) -> [Float] {
        rawData.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Int16.self)
            if channels == 1 {
                return values.prefix(frameCount).map { Float($0) / Float(Int16.max) }
            }
            var mixed = [Float]()
            mixed.reserveCapacity(frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                let baseIndex = frame * channels
                for channel in 0..<channels {
                    sum += Float(values[baseIndex + channel]) / Float(Int16.max)
                }
                mixed.append(sum / Float(channels))
            }
            return mixed
        }
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case notRecording
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case audioDeviceStartFailed(OSStatus)
    case inputDeviceUnavailable(String)
    case captureSessionSetupFailed(String)
    case noAudioCaptured

    var errorDescription: String? {
        switch self {
        case .notRecording:                          return "Not currently recording"
        case .tapCreationFailed(let s):              return "Failed to create audio tap (err \(s))"
        case .aggregateDeviceCreationFailed(let s):  return "Failed to create aggregate device (err \(s))"
        case .ioProcCreationFailed(let s):           return "Failed to create IOProc (err \(s))"
        case .audioDeviceStartFailed(let s):         return "Failed to start audio device (err \(s))"
        case .inputDeviceUnavailable(let reason):    return reason
        case .captureSessionSetupFailed(let reason): return "Failed to configure microphone capture: \(reason)"
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
