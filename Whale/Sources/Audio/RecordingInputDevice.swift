import Foundation

struct RecordingInputDevice: Sendable {
    let uniqueID: String
    let name: String
    let transportType: UInt32?
    let transportLabel: String
    let isBluetooth: Bool
}
