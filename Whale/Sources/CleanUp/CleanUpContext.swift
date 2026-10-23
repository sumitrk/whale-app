import Foundation

/// Where the text is going, which decides its layout.
enum CleanUpContext {
    case general
    /// A mail app: the greeting and sign-off get their own paragraphs.
    case email

    private static let mailApps: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",
        "com.superhuman.electron",
        "com.mimestream.Mimestream",
        "it.bloop.airmail2",
        "io.canarymail.mac",
        "com.hey.app.desktop",
    ]

    /// `.email` for a known mail app when email layout is on, `.general` otherwise.
    init(bundleID: String?, emailLayout: Bool) {
        if emailLayout, let bundleID, Self.mailApps.contains(bundleID) {
            self = .email
        } else {
            self = .general
        }
    }
}
