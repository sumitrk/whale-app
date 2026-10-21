import Foundation

/// Turns raw microphone readings into a level that moves smoothly from frame to frame.
///
/// Rises fast so speech shows up at once, falls slowly so the bars don't flicker between
/// syllables. Time constants rather than per-frame factors, so it behaves the same at 60 Hz
/// and 120 Hz. A class, mutated from inside `Canvas` each frame, because writing SwiftUI state
/// there would schedule another render for every frame drawn.
final class LevelEnvelope {
    private var value: Double = 0
    private var lastTime: Double?

    private let attack: Double = 0.045
    private let release: Double = 0.18

    func next(target: Double, at time: Double) -> Double {
        let dt = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastTime = time
        let tau = target > value ? attack : release
        value += (target - value) * (1 - exp(-dt / tau))
        return value
    }
}
