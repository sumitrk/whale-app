import AVFoundation

/// The start and finish sounds, played off the main thread.
///
/// They play at the moment recording starts, when the HUD is springing in. `NSSound.play()`
/// held the main thread for about 50ms each time, so each sound is an `AVAudioPlayer` loaded
/// and prepared once, and played from its own queue.
enum FeedbackSound: String, CaseIterable {
    case start = "Blow"
    case finish = "Bottle"

    private static let queue = DispatchQueue(label: "com.sumitrk.whale.feedback-sound", qos: .userInteractive)
    /// Only touched on `queue`.
    nonisolated(unsafe) private static var players: [FeedbackSound: AVAudioPlayer] = [:]

    /// Loads and prepares every sound, so the first press doesn't pay for it.
    static func preload() {
        queue.async {
            for sound in allCases { _ = sound.player() }
        }
    }

    func play() {
        Self.queue.async {
            guard let player = player() else { return }
            player.currentTime = 0
            player.play()
        }
    }

    private func player() -> AVAudioPlayer? {
        if let player = Self.players[self] { return player }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(rawValue).aiff")
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.prepareToPlay()
        Self.players[self] = player
        return player
    }
}
