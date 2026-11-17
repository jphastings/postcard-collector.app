import Foundation

/// An org.dotpostcard.collection record, as the Go core lists it.
struct AtprotoCollection: Codable, Hashable, Identifiable, Sendable {
    let uri: String
    let cid: String
    let title: String
    let cardCount: Int
    let createdAt: String
    /// The at-uris of the collection's postcard records, in order.
    let postcards: [String]

    var id: String { uri }
}

/// An org.dotpostcard.follow record. `uri` is the follow record's own.
struct AtprotoFollow: Codable, Hashable, Sendable {
    let uri: String
    let subject: String
    let createdAt: String
}

/// A postcard record fetched into a cached collection file: its at-uri, which is stable, and its
/// card's name in that file, which can change between fetches.
struct AtprotoFetchedCard: Codable, Hashable, Sendable {
    let uri: String
    let name: String
}

/// What's remembered beside a cached collection file about the fetch that wrote it.
struct AtprotoCollectionSidecar: Codable, Equatable, Sendable {
    /// The collection record's cid when it was fetched.
    var cid: String
    var cards: [AtprotoFetchedCard]
}

/// Where Atmosphere collections are cached: `<root>/<did>/<rkey>.postcards`, with a
/// `<rkey>.json` sidecar beside each.
enum AtmosphereCache {
    static var defaultRoot: URL {
        #if os(macOS)
        // Unsandboxed, so Caches is shared with every other app.
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "org.dotpostcard.collector").appending(path: "Atmosphere")
        #else
        URL.cachesDirectory.appending(path: "Atmosphere")
        #endif
    }

    /// The record key: the at-uri's last path segment. `nil` for anything that isn't a valid
    /// rkey, which a PDS could otherwise use to point a cache path elsewhere.
    static func rkey(of uri: String) -> String? {
        guard uri.hasPrefix("at://"), let last = uri.split(separator: "/").last.map(String.init),
              last != ".", last != "..", last.count <= 512,
              last.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:~-".contains($0)) })
        else { return nil }
        return last
    }

    static func accountDirectory(root: URL, did: String) -> URL {
        root.appending(path: did, directoryHint: .isDirectory)
    }

    static func collectionURL(root: URL, did: String, uri: String) -> URL? {
        rkey(of: uri).map { accountDirectory(root: root, did: did).appending(path: "\($0).postcards") }
    }

    static func sidecarURL(forCollectionAt url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("json")
    }

    /// The last good listing of an account's collections, beside its folder so no rkey can
    /// collide with it.
    static func listingURL(root: URL, did: String) -> URL {
        root.appending(path: "\(did).json")
    }

    static func readSidecar(forCollectionAt url: URL) -> AtprotoCollectionSidecar? {
        guard let data = try? Data(contentsOf: sidecarURL(forCollectionAt: url)) else { return nil }
        return try? JSONDecoder().decode(AtprotoCollectionSidecar.self, from: data)
    }

    static func writeSidecar(_ sidecar: AtprotoCollectionSidecar, forCollectionAt url: URL) throws {
        try JSONEncoder().encode(sidecar).write(to: sidecarURL(forCollectionAt: url), options: .atomic)
    }

    /// A cached collection is only fetched again once its record has changed.
    static func needsFetch(isCached: Bool, recordCID: String, sidecar: AtprotoCollectionSidecar?) -> Bool {
        !isCached || sidecar?.cid != recordCID
    }
}

extension AtmosphereCache {
    /// A cached file is complete once a fetch of it has finished and its record's cid is stored
    /// beside it. Until then it's partial: the cards committed so far, which the next fetch resumes.
    static func isComplete(sidecar: AtprotoCollectionSidecar?) -> Bool {
        !(sidecar?.cid.isEmpty ?? true)
    }

    /// Whether a cached collection can be browsed: once complete (even if the collection is
    /// empty), or once a partial download holds at least one card.
    static func isBrowsable(isComplete: Bool, cardCount: Int) -> Bool {
        isComplete || cardCount > 0
    }
}

/// How far a running fetch has got, from its per-card callbacks.
struct CollectionFetchProgress: Equatable, Sendable {
    /// Cards handled so far, of `total`. Both stay 0 until the first card lands.
    var done = 0
    var total = 0

    /// How full the progress ring is; `nil` until the total is known.
    var fraction: Double? {
        total > 0 ? min(Double(done) / Double(total), 1) : nil
    }

    /// How many cards are still to come; `nil` until the total is known.
    var remaining: Int? {
        total > 0 ? max(total - done, 0) : nil
    }
}

/// Spaces out reloads of a collection that grows card by card, so a 700-card download reloads its
/// grid a couple of times a second rather than 700 times, and the last change always gets one.
struct ReloadThrottle {
    let interval: TimeInterval
    private var lastReload = -TimeInterval.infinity
    private var isPending = false

    init(interval: TimeInterval = 0.5) {
        self.interval = interval
    }

    /// For a change at `now`: how many seconds until the reload that shows it, or `nil` when a
    /// reload already pending will.
    mutating func schedule(at now: TimeInterval) -> TimeInterval? {
        guard !isPending else { return nil }
        isPending = true
        return max(0, lastReload + interval - now)
    }

    mutating func didReload(at now: TimeInterval) {
        isPending = false
        lastReload = now
    }
}
