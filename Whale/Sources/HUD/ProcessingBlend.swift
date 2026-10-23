import Foundation

/// Eases the bars between their live shape and the processing wave over a fraction of a
/// second. Time-based and mutated inside `Canvas`, like `LevelEnvelope`, for the same reasons.
final class ProcessingBlend {
    private var value: Double?
    private var lastTime: Double?
    private let tau: Double = 0.12

    func next(target: Double, at time: Double) -> Double {
        // The first frame starts where it's asked to, so a pill that opens processing doesn't
        // play the live bars first.
        guard let current = value else {
            value = target
            lastTime = time
            return target
        }
        let dt = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastTime = time
        let next = current + (target - current) * (1 - exp(-dt / tau))
        value = next
        return next
    }
}
