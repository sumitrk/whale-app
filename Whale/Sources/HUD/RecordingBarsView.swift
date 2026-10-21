import SwiftUI

/// The five bars in the recording HUD, drawn once per display frame.
///
/// Heights come from the smoothed mic level plus a slow per-bar wave, so they flow instead of
/// jumping to random heights several times a second. Silence settles into the resting shape.
/// One `Canvas` inside a `TimelineView` is a single cheap draw per frame — no per-bar views
/// to diff, and nothing invalidated by the audio thread.
struct RecordingBarsView: View {
    let meter: MicLevelMeter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var envelope = LevelEnvelope()

    private static let restingHeights: [Double] = [8, 13, 18, 13, 8]
    private static let weights: [Double] = [0.6, 0.85, 1, 0.85, 0.6]
    private static let minHeight: Double = 3
    private static let maxHeight: Double = 20
    private static let barWidth: Double = 3
    private static let spacing: Double = 3

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let level = envelope.next(target: Double(meter.current), at: time)
                draw(level: level, time: time, in: &context, size: size)
            }
        }
        .frame(width: 27, height: 20)
        .accessibilityLabel("Recording")
    }

    private func draw(level: Double, time: Double, in context: inout GraphicsContext, size: CGSize) {
        // Perceptual curve: quiet speech still moves the bars visibly.
        let loudness = min(1, pow(level, 0.7))
        let count = Self.restingHeights.count

        for index in 0..<count {
            let wave = reduceMotion ? 1 : 0.78 + 0.22 * sin(time * (5.2 + Double(index) * 0.9) + Double(index) * 1.3)
            let active = Self.minHeight + (Self.maxHeight - Self.minHeight) * loudness * Self.weights[index] * wave
            let breathing = reduceMotion ? 1 : 0.94 + 0.06 * sin(time * 2.4 + Double(index) * 0.8)
            let resting = Self.restingHeights[index] * breathing
            let height = resting + (active - resting) * min(1, loudness * 4)

            let x = Double(index) * (Self.barWidth + Self.spacing)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
            context.fill(Capsule().path(in: rect), with: .color(.white.opacity(0.85)))
        }
    }
}
