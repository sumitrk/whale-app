import Foundation
import QuartzCore

/// The latest microphone level, shared between the capture thread and the HUD.
///
/// The HUD smooths it per frame, so this only holds the newest reading and when it arrived:
/// a reading older than `staleAfter` counts as silence, which is what lets the bars settle when
/// the mic stops delivering buffers without a timer to decay them.
final class MicLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 0
    private var updatedAt: CFTimeInterval = 0
    private var signal = false
    private let staleAfter: CFTimeInterval = 0.15

    func record(_ newLevel: Float) {
        let now = CACurrentMediaTime()
        lock.lock()
        level = newLevel
        updatedAt = now
        lock.unlock()
    }

    /// 0…1, or 0 when no buffer has arrived recently.
    var current: Float {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        return now - updatedAt > staleAfter ? 0 : level
    }

    /// Whether a buffer has arrived since the last reset. Lets the capture thread announce
    /// the first buffer once instead of hopping to the main thread for every one.
    var hasSignal: Bool {
        get { lock.lock(); defer { lock.unlock() }; return signal }
        set { lock.lock(); signal = newValue; lock.unlock() }
    }

    func reset() {
        lock.lock()
        level = 0
        updatedAt = 0
        signal = false
        lock.unlock()
    }
}
