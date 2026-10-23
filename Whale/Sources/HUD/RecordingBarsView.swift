import SwiftUI

/// The seven bars in the HUD, drawn once per display frame.
///
/// While recording, heights come from the smoothed mic level plus a slow per-bar wave, so they
/// flow instead of jumping to random heights several times a second; silence settles into the
/// resting shape. While processing, the same bars blend into a sine wave travelling across them.
/// One `Canvas` inside a `TimelineView` is a single cheap draw per frame — no per-bar views
/// to diff, and nothing invalidated by the audio thread.
struct RecordingBarsView: View {
    let meter: MicLevelMeter?
    let isProcessing: Bool
    var isPaused = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var envelope = LevelEnvelope()
    @State private var blend = ProcessingBlend()

    private static let restingHeights: [Double] = [6, 9, 13, 18, 13, 9, 6]
    private static let weights: [Double] = [0.5, 0.7, 0.88, 1, 0.88, 0.7, 0.5]
    private static let minHeight: Double = 3
    private static let maxHeight: Double = 20
    private static let barWidth: Double = 3
    private static let spacing: Double = 3
    private static var width: Double {
        let count = Double(restingHeights.count)
        return count * barWidth + (count - 1) * spacing
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: isPaused)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let level = envelope.next(target: Double(meter?.current ?? 0), at: time)
                let processing = blend.next(target: isProcessing ? 1 : 0, at: time)
                draw(level: level, processing: processing, time: time, in: &context, size: size)
            }
        }
        .frame(width: Self.width, height: Self.maxHeight)
        .accessibilityLabel(isProcessing ? "Transcribing" : "Recording")
    }

    private func draw(level: Double, processing: Double, time: Double, in context: inout GraphicsContext, size: CGSize) {
        // Perceptual curve: quiet speech still moves the bars visibly.
        let loudness = min(1, pow(level, 0.7))
        let count = Self.restingHeights.count

        for index in 0..<count {
            let wave = reduceMotion ? 1 : 0.78 + 0.22 * sin(time * (5.2 + Double(index) * 0.9) + Double(index) * 1.3)
            let active = Self.minHeight + (Self.maxHeight - Self.minHeight) * loudness * Self.weights[index] * wave
            let breathing = reduceMotion ? 1 : 0.94 + 0.06 * sin(time * 2.4 + Double(index) * 0.8)
            let resting = Self.restingHeights[index] * breathing
            let live = resting + (active - resting) * min(1, loudness * 4)

            // One crest rolling left to right, a little under once a second.
            let phase = reduceMotion ? 0 : time * 5.5 - Double(index) * 0.85
            let sine = 5 + 12 * (0.5 + 0.5 * sin(phase))
            let height = live + (sine - live) * processing

            let x = Double(index) * (Self.barWidth + Self.spacing)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: Self.barWidth, height: height)
            context.fill(Capsule().path(in: rect), with: .color(.white.opacity(0.9)))
        }
    }
}
