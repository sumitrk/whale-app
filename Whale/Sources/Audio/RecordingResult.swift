import Foundation

struct RecordingResult: Sendable {
    let wavURL: URL
    let capturedSampleCount16k: Int
    let writtenSampleCount16k: Int
    let durationSeconds: Double
    let inputDeviceName: String
    let isBluetoothInput: Bool
    let wasPaddedForASR: Bool
}
