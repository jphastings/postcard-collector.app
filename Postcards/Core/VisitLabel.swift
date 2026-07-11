import Foundation

/// Formats a person's contact URL into the label shown for `CardInfoPanel`'s "Visit …" menu
/// item — pulled out as a pure function so the host/path formatting rules are testable without
/// standing up the menu itself.
enum VisitLabel {
    /// "Visit host" (or "Visit host/path" when there's a meaningful path), e.g.
    /// `https://www.instagram.com/claire.durrant88/` → "Visit instagram.com/claire.durrant88",
    /// `https://byjp.me` → "Visit byjp.me". The host drops a leading "www." and the path drops
    /// its trailing slash; a path of just "/" is treated as no path at all, since a bare domain
    /// has nothing meaningful past the host to show.
    static func text(for url: URL) -> String {
        guard let host = url.host, !host.isEmpty else {
            return fallbackText(for: url)
        }
        let trimmedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "Visit \(trimmedHost)" : "Visit \(trimmedHost)\(path)"
    }

    /// Falls back to the raw URI with its scheme prefix trimmed off, for the rare contact URL
    /// with no host at all — so at least something readable shows instead of just the scheme.
    private static func fallbackText(for url: URL) -> String {
        var trimmed = url.absoluteString
        if let scheme = url.scheme {
            for prefix in ["\(scheme)://", "\(scheme):"] where trimmed.hasPrefix(prefix) {
                trimmed.removeFirst(prefix.count)
                break
            }
        }
        return "Visit \(trimmed)"
    }
}
