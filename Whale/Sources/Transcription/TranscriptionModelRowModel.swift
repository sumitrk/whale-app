import CoreML
import FluidAudio
import Foundation
import WhisperKit

/// The one-line state a model row reports. Deliberately separate from
/// `NativeModelInstallState`: install state is about the bytes on disk, this is what the
/// settings row says, which also folds in whether the model is the selected one.
enum TranscriptionModelStatus: Equatable {
    /// Selected for transcription. The download action can still be shown when its files are missing.
    case active
    /// Installed but not selected.
    case inactive
    case notInstalled
    /// A download, validation, or cache check is in flight. Carries the phase text.
    case working(String)
    case needsAttention

    var text: String {
        switch self {
        case .active:              return "In use"
        case .inactive:            return "Downloaded"
        case .notInstalled:        return "Not installed"
        case .working(let phase):  return phase
        case .needsAttention:      return "Needs attention"
        }
    }

    /// Transient work gets a spinner in the row's trailing slot instead of a status dot.
    var showsDot: Bool {
        if case .working = self { return false }
        return true
    }
}

struct TranscriptionModelRowModel: Equatable {
    let status: TranscriptionModelStatus
    let primaryActionTitle: String?
    let progress: Double?
    let isBusy: Bool
    let errorText: String?
    let resetActionTitle: String?
    let isReady: Bool
    /// Whether to offer abandoning the work in flight.
    ///
    /// Only a running install earns it. A `checking` pass is sub-second and happens every time
    /// the pane appears, so a Cancel button there would do nothing but flicker on three rows.
    let isCancellable: Bool

    var statusText: String { status.text }

    /// The line under a model's name: what it can do, then what you'd need to do to use it.
    /// Whether it's in use isn't repeated here — the row's trailing badge or button says that.
    func statusLine(capabilityLabel: String, downloadSize: String?) -> String {
        switch status {
        case .working:
            return statusText
        case .needsAttention:
            return "\(statusText) · \(capabilityLabel)"
        case .active, .inactive, .notInstalled:
            guard !isReady else { return capabilityLabel }
            return "\(capabilityLabel) · " + (downloadSize.map { "\($0) download" } ?? statusText)
        }
    }

    init(
        model: BuiltInModelDescriptor,
        installState: NativeModelInstallState,
        isSelected: Bool
    ) {
        switch installState {
        case .checking:
            status = .working("Checking…")
            primaryActionTitle = nil
            progress = nil
            isBusy = true
            errorText = nil
            resetActionTitle = nil
            isReady = false
            isCancellable = false

        case .notInstalled:
            // Keep the selected row visually active even before its files are downloaded. The
            // Download action makes the next step clear without turning a missing model into
            // an error state.
            status = isSelected ? .active : .notInstalled
            primaryActionTitle = model.actionTitle
            progress = nil
            isBusy = false
            errorText = nil
            resetActionTitle = nil
            isReady = false
            isCancellable = false

        case .downloading(let fraction, let phase):
            let percent = fraction.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            status = .working(phase + percent)
            primaryActionTitle = nil
            progress = fraction
            isBusy = true
            errorText = nil
            resetActionTitle = nil
            isReady = false
            isCancellable = true

        case .ready:
            // A model only reads "Active" while it is genuinely usable. Selection is never
            // reassigned behind the user's back, so an uninstalled-but-selected model just
            // reads "Not Installed" and nothing in the list claims to be active.
            status = isSelected ? .active : .inactive
            primaryActionTitle = model.changeActionTitle
            progress = nil
            isBusy = false
            errorText = nil
            resetActionTitle = model.resetActionTitle
            isReady = true
            isCancellable = false

        case .failed(let message):
            status = .needsAttention
            primaryActionTitle = model.retryActionTitle
            progress = nil
            isBusy = false
            errorText = message
            resetActionTitle = model.resetActionTitle
            isReady = false
            isCancellable = false
        }
    }
}
