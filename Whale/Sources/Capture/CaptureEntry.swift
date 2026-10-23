import Foundation

/// The History Entry a capture writes to, when its intent keeps one.
struct CaptureEntry {
    let id: UUID
    let history: CaptureHistory
}
