import AppKit

/// Everything we know about the app a history entry came from, and how to turn
/// that into an icon.
///
/// Display names are a bad key: the folder on disk is often named something
/// else ("Code.app" for "Visual Studio Code"), and an app installed outside the
/// handful of directories we know about is invisible to a filesystem walk. The
/// bundle identifier is the key LaunchServices itself indexes, so prefer it and
/// keep the name search only for entries recorded before we stored one.
enum SourceApp {
    /// `FocusedElementInspector` substitutes the literal string "unknown" when
    /// AppKit gives it nothing; never persist that as an identifier.
    static func bundleID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "unknown" else { return nil }
        return trimmed
    }

    private static let cache = NSCache<NSString, NSImage>()

    static func icon(bundleID: String?, name: String?) -> NSImage? {
        let key = (bundleID ?? name)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { return nil }
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let url = applicationURL(bundleID: bundleID, name: name) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    static func applicationURL(bundleID: String?, name: String?) -> URL? {
        if let bundleID = Self.bundleID(bundleID),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        return applicationURL(named: name)
    }

    /// Fallback for pre-0.8.1 rows that only ever recorded a display name.
    private static func applicationURL(named name: String?) -> URL? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame
        }), let url = running.bundleURL {
            return url
        }

        for root in searchRoots {
            let direct = root.appendingPathComponent("\(trimmed).app")
            if FileManager.default.fileExists(atPath: direct.path) {
                return direct
            }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in contents where item.pathExtension == "app" {
                if Bundle(url: item)?.localizedName?.caseInsensitiveCompare(trimmed) == .orderedSame {
                    return item
                }
            }
            for item in contents where item.pathExtension.isEmpty {
                let nested = item.appendingPathComponent("\(trimmed).app")
                if FileManager.default.fileExists(atPath: nested.path) {
                    return nested
                }
            }
        }
        return nil
    }

    private static var searchRoots: [URL] {
        var roots = FileManager.default.urls(
            for: .applicationDirectory,
            in: [.localDomainMask, .userDomainMask, .systemDomainMask]
        )
        roots.append(URL(fileURLWithPath: "/Applications/Utilities"))
        roots.append(URL(fileURLWithPath: "/System/Applications"))
        roots.append(URL(fileURLWithPath: "/System/Applications/Utilities"))
        roots.append(URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications"))
        return roots
    }
}

private extension Bundle {
    /// The name Finder and the Dock show, which is what we recorded.
    var localizedName: String? {
        (localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (infoDictionary?["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
    }
}
