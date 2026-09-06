import Combine
import Foundation

/// What OpenRouter last said about the stored key.
///
/// `unreachable` is deliberately distinct from `invalid`: a key we could not
/// ask about is not a key we know to be bad, and conflating the two greets
/// anyone who opens the lid on a dead network with a false alarm.
enum KeyVerification: Equatable {
    case unknown
    case checking
    case valid
    case invalid(String)
    case unreachable
}

enum KeySaveResult: Equatable {
    case saved
    case failed(String)
}

/// Verifies a key against OpenRouter's key-introspection endpoint. It bills no
/// tokens, so it is cheap enough to run on every launch, and the response body
/// is never read — we want the verdict, not the account metadata.
enum OpenRouterKeyVerifier {
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/key")!
    static let keysPage = URL(string: "https://openrouter.ai/keys")!
    static let creditsPage = URL(string: "https://openrouter.ai/credits")!

    /// Anything that is not an explicit "yes" or "no" from OpenRouter — 5xx,
    /// 429, a redirect to a captive portal — says nothing about the key.
    static func outcome(forStatusCode code: Int) -> KeyVerification {
        switch code {
        case 200: return .valid
        case 401, 403: return .invalid("OpenRouter rejected this key.")
        default: return .unreachable
        }
    }

    static func verify(key: String, session: URLSession = .shared) async -> KeyVerification {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable }
            return outcome(forStatusCode: http.statusCode)
        } catch {
            return .unreachable
        }
    }
}

/// Classifies a failed AI Action so an exhausted account stops masquerading as
/// a bad key. The two need different words and different remedies: one is
/// "replace this", the other is "top this up".
enum OpenRouterFailure: Equatable {
    case rejectedKey
    case outOfCredit

    /// Credit is checked first — a 402 body rarely mentions 401, but both
    /// mention "credits", so the narrower match has to win.
    static func classify(_ message: String) -> OpenRouterFailure? {
        let value = message.lowercased()
        let creditMarkers = [
            "402", "payment required", "insufficient credit", "insufficient_quota",
            "insufficient funds", "more credits", "out of credit", "add credits",
        ]
        if creditMarkers.contains(where: value.contains) { return .outOfCredit }
        let keyMarkers = ["401", "unauthorized", "invalid api key", "no auth credentials"]
        if keyMarkers.contains(where: value.contains) { return .rejectedKey }
        return nil
    }
}

/// The single row the AI Actions panel shows. Derived, not stored — every
/// input that can make the connection unusable folds into one worst-of verdict
/// so the panel never asks the reader to reconcile two rows that disagree.
struct AIConnectionStatus: Equatable {
    enum Indicator: Equatable { case neutral, good, bad }

    var indicator: Indicator
    var label: String
    var detail: String?
    var showsRetry: Bool
    var showsTopUpLink: Bool

    static func make(
        hasKey: Bool,
        verification: KeyVerification,
        runtime: PiRuntimeStatus,
        lastKnownGood: Bool,
        keyRejected: Bool,
        outOfCredit: Bool
    ) -> AIConnectionStatus {
        guard hasKey else {
            return AIConnectionStatus(
                indicator: .neutral,
                label: "Not connected",
                detail: nil,
                showsRetry: false,
                showsTopUpLink: false
            )
        }

        if case .invalid(let message) = verification {
            return AIConnectionStatus(
                indicator: .bad, label: "Invalid key", detail: message,
                showsRetry: true, showsTopUpLink: false
            )
        }
        if keyRejected {
            return AIConnectionStatus(
                indicator: .bad, label: "Invalid key",
                detail: "OpenRouter rejected this key. Replace it to keep using AI Actions.",
                showsRetry: true, showsTopUpLink: false
            )
        }
        if outOfCredit {
            return AIConnectionStatus(
                indicator: .bad, label: "Out of credit",
                detail: "OpenRouter refused the last request for lack of credit.",
                showsRetry: false, showsTopUpLink: true
            )
        }
        // A re-check on top of a known-good key is background work — saying
        // "Checking…" would blank out a correct answer we already have.
        if verification == .checking && !lastKnownGood {
            return AIConnectionStatus(
                indicator: .neutral, label: "Checking…", detail: nil,
                showsRetry: false, showsTopUpLink: false
            )
        }
        // A stopped or starting engine is not a fault — it warms on demand.
        // Only an engine that failed outright is worth the reader's attention.
        if case .unavailable(let reason) = runtime {
            return AIConnectionStatus(
                indicator: .bad, label: "Unavailable", detail: reason,
                showsRetry: true, showsTopUpLink: false
            )
        }

        switch verification {
        case .valid:
            return AIConnectionStatus(
                indicator: .good, label: "Connected", detail: nil,
                showsRetry: false, showsTopUpLink: false
            )
        case .unreachable where lastKnownGood:
            return AIConnectionStatus(
                indicator: .good, label: "Connected",
                detail: "Couldn't re-check — you appear to be offline.",
                showsRetry: true, showsTopUpLink: false
            )
        case .unknown where lastKnownGood, .checking where lastKnownGood:
            return AIConnectionStatus(
                indicator: .good, label: "Connected", detail: nil,
                showsRetry: false, showsTopUpLink: false
            )
        default:
            return AIConnectionStatus(
                indicator: .neutral, label: "Not verified", detail: nil,
                showsRetry: true, showsTopUpLink: false
            )
        }
    }
}

/// Owns the stored OpenRouter key and everything we know about whether it
/// works. Shared by the launch check and the settings panel so both read the
/// same verdict.
@MainActor
final class OpenRouterConnection: ObservableObject {
    @Published private(set) var verification: KeyVerification = .unknown
    @Published private(set) var hasKey: Bool = false

    /// How long a verdict stays fresh. Opening the AI Actions tab should not
    /// cost an OpenRouter round trip every time.
    static let freshness: TimeInterval = 5 * 60

    private let settings: SettingsStore
    private let verifier: (String) async -> KeyVerification
    private let now: () -> Date
    private var verifyTask: Task<Void, Never>?
    private var lastVerifiedAt: Date?

    init(
        settings: SettingsStore = .shared,
        verifier: @escaping (String) async -> KeyVerification = {
            await OpenRouterKeyVerifier.verify(key: $0)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.verifier = verifier
        self.now = now
        self.hasKey = Self.storedKey() != nil
    }

    func status(runtime: PiRuntimeStatus) -> AIConnectionStatus {
        AIConnectionStatus.make(
            hasKey: hasKey,
            verification: verification,
            runtime: runtime,
            lastKnownGood: settings.openRouterKeyVerified,
            keyRejected: settings.openRouterKeyRejected,
            outOfCredit: settings.openRouterOutOfCredit
        )
    }

    /// Re-checks the stored key. Safe to call repeatedly — a check already in
    /// flight is cancelled rather than raced, and a verdict from the last few
    /// minutes is reused unless the caller insists.
    func verifyNow(force: Bool = false) {
        guard let key = Self.storedKey() else {
            verifyTask?.cancel()
            lastVerifiedAt = nil
            hasKey = false
            verification = .unknown
            return
        }
        hasKey = true
        if !force, isFresh { return }
        verifyTask?.cancel()
        verification = .checking
        verifyTask = Task { [weak self] in
            let outcome = await self?.verifier(key)
            guard !Task.isCancelled, let self, let outcome else { return }
            self.apply(outcome)
        }
    }

    /// True while there is nothing worth asking OpenRouter again. A check
    /// already in flight counts; an unreachable network does not, so a failed
    /// re-check is retried on the next visit.
    private var isFresh: Bool {
        if verification == .checking { return true }
        guard case .valid = verification, let lastVerifiedAt else { return false }
        return now().timeIntervalSince(lastVerifiedAt) < Self.freshness
    }

    /// Verifies before committing, so a truncated paste can never destroy a
    /// working key. Nothing touches the Keychain until OpenRouter says yes.
    func save(key: String) async -> KeySaveResult {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .failed("Enter a key first.") }

        switch await verifier(value) {
        case .valid:
            do {
                try KeychainStore.set(value, for: .openRouterAPIKey)
            } catch {
                return .failed(error.localizedDescription)
            }
            settings.openRouterKeyRejected = false
            settings.openRouterOutOfCredit = false
            settings.openRouterKeyVerified = true
            hasKey = true
            verification = .valid
            lastVerifiedAt = now()
            return .saved
        case .invalid(let message):
            return .failed(message)
        case .unreachable:
            return .failed("Couldn't reach OpenRouter to check this key. Check your connection and try again.")
        case .checking, .unknown:
            return .failed("Couldn't check this key. Try again.")
        }
    }

    func remove() -> String? {
        verifyTask?.cancel()
        do {
            try KeychainStore.delete(.openRouterAPIKey)
        } catch {
            return error.localizedDescription
        }
        settings.openRouterKeyRejected = false
        settings.openRouterOutOfCredit = false
        settings.openRouterKeyVerified = false
        hasKey = false
        verification = .unknown
        lastVerifiedAt = nil
        return nil
    }

    private func apply(_ outcome: KeyVerification) {
        verification = outcome
        switch outcome {
        case .valid, .invalid:
            lastVerifiedAt = now()
        case .unreachable, .checking, .unknown:
            break
        }
        switch outcome {
        case .valid:
            settings.openRouterKeyVerified = true
            settings.openRouterKeyRejected = false
        case .invalid:
            settings.openRouterKeyVerified = false
            settings.openRouterKeyRejected = true
        // An unanswered question leaves the cached verdict exactly as it was.
        case .unreachable, .checking, .unknown:
            break
        }
    }

    private static func storedKey() -> String? {
        guard let key = try? KeychainStore.string(for: .openRouterAPIKey), !key.isEmpty else {
            return nil
        }
        return key
    }
}
