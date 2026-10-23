import AVFoundation
import CoreAudio

/// Finding the microphone to record from, and describing it for the logs. Prefers the built-in
/// microphone over a Bluetooth headset's, which drops audio quality for everything playing.
enum InputDevices {
    static func defaultInput() throws -> RecordingInputDevice {
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

    private static func builtInInputDevice() -> RecordingInputDevice? {
        availableInputDevices()
            .first { isBuiltInTransport(UInt32(bitPattern: $0.transportType)) }
            .map(recordingInputDevice(for:))
    }

    private static func availableInputDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func captureDevice(for uniqueID: String) -> AVCaptureDevice? {
        availableInputDevices().first { $0.uniqueID == uniqueID }
    }

    private static func recordingInputDevice(for captureDevice: AVCaptureDevice) -> RecordingInputDevice {
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

    private static func isBluetoothTransport(_ transportType: UInt32?) -> Bool {
        guard let transportType else { return false }
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func isBuiltInTransport(_ transportType: UInt32?) -> Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }

    private static func transportLabel(for transportType: UInt32?) -> String {
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

    static func inferredBluetoothDeviceName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let bluetoothMarkers = ["airpods", "buds", "beats", "bluetooth", "headset"]
        return bluetoothMarkers.contains { lowered.contains($0) }
    }

    private static func fourCharCodeString(_ value: UInt32) -> String {
        let scalarBytes: [UnicodeScalar] = [
            UnicodeScalar((value >> 24) & 0xFF),
            UnicodeScalar((value >> 16) & 0xFF),
            UnicodeScalar((value >> 8) & 0xFF),
            UnicodeScalar(value & 0xFF),
        ].compactMap { $0 }
        let string = String(String.UnicodeScalarView(scalarBytes))
        return string.trimmingCharacters(in: .controlCharacters)
    }
}
