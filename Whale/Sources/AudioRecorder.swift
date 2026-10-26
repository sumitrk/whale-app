import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import QuartzCore

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
    /// Normalised microphone level, written from the capture thread for every buffer and
    /// read by the recording HUD once per display frame. Deliberately not `@Published`: a
    /// main-thread hop and an `objectWillChange` per audio buffer re-rendered every observer
    /// of the recorder dozens of times a second.
    let levelMeter = MicLevelMeter()
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
    private let micSessionQueue = DispatchQueue(
        label: "Whale.AudioRecorder.MicSession",
        qos: .userInitiated
    )
    private var inputDeviceChangeListener: AudioObjectPropertyListenerBlock?
    private var captureDeviceDisconnectObserver: (any NSObjectProtocol)?
    private var micRestartWorkItem: DispatchWorkItem?
    private var idleRewarmWorkItem: DispatchWorkItem?
    private var isStartingRecording = false
    private var isRestartingMicCapture = false
    private var currentInputDeviceUniqueID: String?
    private var currentInputDevice: RecordingInputDevice?
    /// Updated from the capture queue and the main thread, so only under `micReadyLock`.
    private var readiness = MicrophoneReadiness()
    private let micReadyLock = NSLock()

    // MARK: - Sample buffers (lock-protected)

    private var systemAudioSamples: [Float] = []
    private var micSamples: [Float] = []
    private let lock = NSLock()

    private var tapSampleRate: Double = 48_000
    private var currentCaptureIncludesSystemAudio = true
    private let bluetoothRestartDelay: TimeInterval = 0.2
    private let bluetoothFallbackRestartDelay: TimeInterval = 0.75
    private var bluetoothStartupValidationWorkItem: DispatchWorkItem?

    // MARK: - Public API

    func activeInputDevice() throws -> RecordingInputDevice {
        if let currentInputDevice {
            return currentInputDevice
        }
        return try InputDevices.defaultInput()
    }

    @MainActor
    func startRecording(captureSystemAudio: Bool = true) async throws {
        guard !isRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }

        // The microphone changed moments ago and the held session hasn't been rebuilt yet:
        // drop it, so this recording builds a fresh one instead of starting a dead device.
        if let pending = idleRewarmWorkItem {
            pending.cancel()
            idleRewarmWorkItem = nil
            teardownMicCapture()
        }

        currentCaptureIncludesSystemAudio = captureSystemAudio
        systemAudioSamples = []
        micSamples = []
        do {
            if captureSystemAudio {
                try startSystemAudioCapture()
            }
            try await startMicCapture()
            levelMeter.reset()
            isRecording = true
            let modeLabel = captureSystemAudio ? "mic + system audio" : "mic only"
            print("AudioRecorder: engine started (\(modeLabel))")
        } catch {
            stopSystemAudioCapture()
            await stopMicCapture()
            levelMeter.reset()
            isRecording = false
            throw error
        }
    }

    @MainActor
    func prepareMicrophoneCapture() {
        guard micCaptureSession == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }

        do {
            try configureMicCapture(for: InputDevices.defaultInput())
            print("AudioRecorder: microphone capture preconfigured")
        } catch {
            print("AudioRecorder: microphone preconfiguration deferred: \(error)")
        }
    }

    @MainActor
    func stopRecording() async throws -> RecordingResult {
        guard isRecording else { throw RecorderError.notRecording }

        stopSystemAudioCapture()
        await stopMicCapture()
        levelMeter.reset()
        isMicActive = false

        isRecording = false
        print("AudioRecorder: recording stopped")

        return try mixAndWriteWAV()
    }

    // MARK: - App-owned storage

    static func recordingsFolder() -> URL {
        let folder = AppRuntimeInfo.current.recordingsDirectoryURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func meetingsFolder() -> URL {
        let folder = AppRuntimeInfo.current.transcriptsDirectoryURL
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
            let buffer = UnsafeBufferPointer(start: data.bindMemory(to: Float.self, capacity: count), count: count)
            samples += AudioProcessing.downmixSystemAudio(buffer, channels: Int(buf.mNumberChannels))
        }
        guard !samples.isEmpty else { return }
        lock.lock()
        systemAudioSamples.append(contentsOf: samples)
        lock.unlock()
    }

    // MARK: - Microphone (AVCaptureSession)

    private func startMicCapture() async throws {
        let startedAt = Date()
        let inputDevice = try InputDevices.defaultInput()
        let capturePolicy: MicrophoneReadiness.Policy =
            !currentCaptureIncludesSystemAudio && inputDevice.isBluetooth ? .bluetooth : .standard

        if micCaptureSession == nil || currentInputDeviceUniqueID != inputDevice.uniqueID {
            teardownMicCapture()
            try configureMicCapture(for: inputDevice)
        }

        let isRestart = isRestartingMicCapture
        withReadiness { $0.begin(capturePolicy, at: startedAt, isRestart: isRestart) }
        micCaptureOutput?.setSampleBufferDelegate(self, queue: micCaptureQueue)

        guard let session = micCaptureSession else {
            throw RecorderError.captureSessionSetupFailed("Microphone capture session was not configured")
        }

        await startCaptureSession(session)
        if capturePolicy == .bluetooth {
            scheduleBluetoothStartupValidation(after: bluetoothFallbackRestartDelay)
        }
        print(
            "AudioRecorder: microphone capture started (device=\(inputDevice.name), " +
            "transport=\(inputDevice.transportLabel), bluetooth=\(inputDevice.isBluetooth), " +
            "policy=\(capturePolicy.label), " +
            "sr=\(Int(AudioProcessing.sampleRate))Hz, ch=1)"
        )
    }

    private func configureMicCapture(for inputDevice: RecordingInputDevice) throws {
        guard let captureDevice = InputDevices.captureDevice(for: inputDevice.uniqueID) else {
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
            AVSampleRateKey: AudioProcessing.sampleRate,
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

        micCaptureSession = session
        micCaptureInput = input
        micCaptureOutput = output
        installInputDeviceListener()
        installCaptureDeviceDisconnectObserver()
    }

    private func startCaptureSession(_ session: AVCaptureSession) async {
        await withCheckedContinuation { continuation in
            micSessionQueue.async {
                session.startRunning()
                continuation.resume()
            }
        }
    }

    private func scheduleMicCaptureRestart(after delay: TimeInterval) {
        micRestartWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.restartMicCapture()
            }
        }
        micRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @MainActor
    private func restartMicCapture() {
        guard isRecording, !isRestartingMicCapture else { return }
        isRestartingMicCapture = true
        let restarts = withReadiness { readiness -> Int? in
            guard readiness.policy == .bluetooth else { return nil }
            readiness.restarting(at: Date())
            return readiness.restartCount
        }
        if let restarts {
            print("AudioRecorder: restarting bluetooth mic capture (\(restarts))")
        }

        teardownMicCapture()

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRestartingMicCapture = false }
            do {
                try await self.startMicCapture()
            } catch {
                print("AudioRecorder: mic restart failed after config change: \(error)")
            }
        }
    }

    private func stopMicCapture() async {
        micRestartWorkItem?.cancel()
        micRestartWorkItem = nil
        bluetoothStartupValidationWorkItem?.cancel()
        bluetoothStartupValidationWorkItem = nil
        isRestartingMicCapture = false
        micCaptureOutput?.setSampleBufferDelegate(nil, queue: nil)
        if let session = micCaptureSession {
            await stopCaptureSession(session)
        }
        withReadiness { $0.clear() }
        await drainPendingMicCaptureCallbacks()
    }

    private func stopCaptureSession(_ session: AVCaptureSession) async {
        await withCheckedContinuation { continuation in
            micSessionQueue.async {
                session.stopRunning()
                continuation.resume()
            }
        }
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
        withReadiness { $0.clear() }
    }

    private func drainPendingMicCaptureCallbacks() async {
        await withCheckedContinuation { continuation in
            micCaptureQueue.async {
                continuation.resume()
            }
        }
    }

    /// Calls `onRecordingReady` the moment the microphone counts as ready.
    private func handleUsableMicSamples() {
        let (becameReady, state) = withReadiness { readiness in
            (readiness.receivedUsableBuffer(at: Date()), readiness)
        }
        if state.policy == .bluetooth {
            if state.usableBufferCount == 1 {
                print("AudioRecorder: first usable bluetooth mic buffer received")
            }
            DispatchQueue.main.async { [weak self] in
                self?.bluetoothStartupValidationWorkItem?.cancel()
                self?.bluetoothStartupValidationWorkItem = nil
            }
        }
        guard becameReady else { return }
        print(
            "AudioRecorder: recording promoted to ready " +
            "(policy=\(state.policy.label), buffers=\(state.usableBufferCount), restarts=\(state.restartCount))"
        )
        Task { @MainActor [weak self] in
            self?.onRecordingReady?()
        }
    }

    private var micCapturePolicy: MicrophoneReadiness.Policy {
        withReadiness { $0.policy }
    }

    private func withReadiness<T>(_ body: (inout MicrophoneReadiness) -> T) -> T {
        micReadyLock.lock()
        defer { micReadyLock.unlock() }
        return body(&readiness)
    }

    private func installInputDeviceListener() {
        guard inputDeviceChangeListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let nextInputUniqueID = try? InputDevices.defaultInput().uniqueID
            guard nextInputUniqueID != self.currentInputDeviceUniqueID else { return }
            guard self.isRecording else {
                self.scheduleIdleMicCaptureRewarm()
                return
            }
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

    private func scheduleBluetoothStartupValidation(after delay: TimeInterval) {
        bluetoothStartupValidationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.validateBluetoothStartup()
        }
        bluetoothStartupValidationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func validateBluetoothStartup() {
        guard isRecording, withReadiness({ $0.needsRestart }) else { return }
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
            guard let self else { return }
            guard let device = notification.object as? AVCaptureDevice else { return }
            guard device.uniqueID == self.currentInputDeviceUniqueID else { return }
            guard self.isRecording else {
                // Plugging the same headset back in reports the same uniqueID, so without
                // this the next recording would reuse a session whose device is gone.
                self.scheduleIdleMicCaptureRewarm()
                return
            }
            print("AudioRecorder: selected microphone disconnected; restarting capture")
            self.scheduleMicCaptureRestart(after: 0.1)
        }
    }

    /// The microphone was unplugged, or the default input changed, while no recording runs.
    /// Rebuilds the held session for the new default right away, so the next recording still
    /// starts instantly. Waits briefly so an unplug's disconnect and default-input change land
    /// as one rebuild.
    private func scheduleIdleMicCaptureRewarm() {
        idleRewarmWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isRecording, !self.isStartingRecording else { return }
                self.idleRewarmWorkItem = nil
                self.teardownMicCapture()
                self.prepareMicrophoneCapture()
                DiagnosticLog.log(
                    "[Audio] Microphone changed while idle; prepared \(self.currentInputDevice?.name ?? "nothing")."
                )
            }
        }
        idleRewarmWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: - Mix + Write WAV

    private func mixAndWriteWAV() throws -> RecordingResult {
        lock.lock()
        let rawSys = systemAudioSamples
        let mic    = micSamples
        lock.unlock()

        let prepared = try AudioProcessing.prepare(
            system: rawSys,
            systemSampleRate: tapSampleRate,
            microphone: mic,
            padsShortRecordings: !currentCaptureIncludesSystemAudio
        )

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "T", with: "_")
            .replacingOccurrences(of: "Z", with: "")
        let url = Self.recordingsFolder().appendingPathComponent("meeting-\(stamp).wav")
        try AudioProcessing.wavData(prepared.samples).write(to: url)

        let kb = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0
        let inputDevice = currentInputDevice
        let inputDeviceName = inputDevice?.name ?? "Unknown Input"
        print(
            "AudioRecorder: WAV saved → \(url.lastPathComponent) (\(kb / 1024) KB, " +
            "captured=\(prepared.capturedCount) samples, written=\(prepared.samples.count) samples, " +
            "padded=\(prepared.wasPadded), device=\(inputDeviceName))"
        )
        let result = RecordingResult(
            wavURL: url,
            capturedSampleCount16k: prepared.capturedCount,
            writtenSampleCount16k: prepared.samples.count,
            durationSeconds: Double(prepared.capturedCount) / AudioProcessing.sampleRate,
            inputDeviceName: inputDeviceName,
            isBluetoothInput: inputDevice?.isBluetooth ?? false,
            wasPaddedForASR: prepared.wasPadded,
            microphonePeak: AudioProcessing.speechPeak(of: mic)
        )
        currentInputDevice = nil
        return result
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
        levelMeter.record(AudioProcessing.level(of: samples))
        if !levelMeter.hasSignal {
            levelMeter.hasSignal = true
            DispatchQueue.main.async {
                if !self.isMicActive { self.isMicActive = true }
            }
        }
    }

    private func extractMicSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return [] }

        let asbd = streamBasicDescription.pointee
        let format = PCMFormat(asbd)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0, !format.isNonInterleaved else { return [] }
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

        guard let samples = AudioProcessing.decode(rawData, frameCount: frameCount, format: format) else {
            print("AudioRecorder: unsupported microphone PCM format (bits=\(asbd.mBitsPerChannel), flags=\(asbd.mFormatFlags))")
            return []
        }
        return samples
    }
}
