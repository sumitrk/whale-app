import Foundation

/// When a starting microphone counts as recording. A wired or built-in microphone is ready at
/// its first usable buffer. A Bluetooth headset switches profile as capture starts and sends a
/// few unusable buffers first, so it's ready only after `bluetoothBufferTarget` usable buffers
/// and `bluetoothQuietPeriod` since the microphone (re)started. Driven by timestamps, not
/// clocks, so the rules are testable.
struct MicrophoneReadiness: Equatable {
    enum Policy: Equatable {
        case standard
        case bluetooth

        var label: String {
            switch self {
            case .standard: "standard"
            case .bluetooth: "bluetooth"
            }
        }
    }

    static let bluetoothBufferTarget = 3
    static let bluetoothQuietPeriod: TimeInterval = 0.25

    private(set) var policy: Policy = .standard
    private(set) var isReady = false
    private(set) var usableBufferCount = 0
    private(set) var restartCount = 0
    private var isAwaitingBluetooth = false
    private var settlingSince: Date?

    /// The microphone started at `date`. A restart keeps counting restarts.
    mutating func begin(_ policy: Policy, at date: Date, isRestart: Bool) {
        self.policy = policy
        isReady = false
        usableBufferCount = 0
        isAwaitingBluetooth = policy == .bluetooth
        settlingSince = date
        if !isRestart { restartCount = 0 }
    }

    /// The Bluetooth route changed and capture is restarting.
    mutating func restarting(at date: Date) {
        guard policy == .bluetooth else { return }
        restartCount += 1
        isAwaitingBluetooth = true
        usableBufferCount = 0
        settlingSince = date
    }

    /// Capture stopped.
    mutating func clear() {
        isReady = false
        isAwaitingBluetooth = false
        usableBufferCount = 0
        settlingSince = nil
    }

    /// A buffer with audio in it arrived at `date`. True exactly once: when it makes the
    /// microphone ready.
    mutating func receivedUsableBuffer(at date: Date) -> Bool {
        guard !isReady else { return false }
        usableBufferCount += 1
        switch policy {
        case .standard:
            isReady = true
        case .bluetooth:
            let quiet = date.timeIntervalSince(settlingSince ?? date) >= Self.bluetoothQuietPeriod
            isReady = quiet && usableBufferCount >= Self.bluetoothBufferTarget
            if isReady { isAwaitingBluetooth = false }
        }
        return isReady
    }

    /// A Bluetooth microphone that hasn't settled by its deadline should be restarted.
    var needsRestart: Bool { policy == .bluetooth && isAwaitingBluetooth && !isReady }
}
