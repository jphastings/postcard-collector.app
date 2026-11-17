import Foundation

/// Which postcards in followed collections are new: those a collection's latest record lists that
/// weren't known when it was first downloaded. Until its collection is opened a new postcard is
/// unseen, which puts a dot on the collection's row; from then it's known, and stays new (for the
/// New search token) until `lifetime` has passed or the app quits, whichever comes first.
///
/// Only the known postcards are saved: when each was first seen is this process's alone.
struct AtmosphereNewPostcards: Codable {
    static let lifetime: TimeInterval = 12 * 60 * 60

    /// The postcard at-uris known in each followed collection, by collection at-uri. Absent until
    /// the collection's first complete download.
    private var known: [String: Set<String>] = [:]
    /// When each new postcard was first seen, by collection at-uri then postcard at-uri.
    private var firstSeen: [String: [String: Date]] = [:]

    private enum CodingKeys: CodingKey { case known }

    static var defaultURL: URL {
        #if os(macOS)
        // Unsandboxed, so Application Support is shared with every other app.
        URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "org.dotpostcard.collector").appending(path: "atmosphere-new-postcards.json")
        #else
        URL.applicationSupportDirectory.appending(path: "atmosphere-new-postcards.json")
        #endif
    }

    /// After a complete download of `collection` holding `postcards`: the first one makes them all
    /// known, so nothing is new. Returns whether anything changed.
    @discardableResult
    mutating func downloaded(_ collection: String, postcards: [String]) -> Bool {
        guard known[collection] == nil else { return false }
        known[collection] = Set(postcards)
        return true
    }

    /// The postcards among `postcards` (the latest record's) that arrived since the first download
    /// and haven't been seen yet.
    func unseen(in collection: String, postcards: [String]) -> [String] {
        guard let known = known[collection] else { return [] }
        return postcards.filter { !known.contains($0) }
    }

    /// The user opened `collection` at `now`: its unseen postcards are seen, and new from then.
    /// Returns whether anything changed.
    @discardableResult
    mutating func open(_ collection: String, postcards: [String], at now: Date) -> Bool {
        let seen = unseen(in: collection, postcards: postcards)
        guard !seen.isEmpty else { return false }
        known[collection, default: []].formUnion(seen)
        for uri in seen { firstSeen[collection, default: [:]][uri] = now }
        return true
    }

    /// The postcards in `collection` that are still new at `now`.
    func new(in collection: String, at now: Date) -> Set<String> {
        Set((firstSeen[collection] ?? [:]).filter { now < $0.value + Self.lifetime }.keys)
    }

    /// Forgets the collections not among `collections`, so following one again starts afresh.
    /// Returns whether anything changed.
    @discardableResult
    mutating func keepOnly(_ collections: Set<String>) -> Bool {
        let before = known.count
        known = known.filter { collections.contains($0.key) }
        firstSeen = firstSeen.filter { collections.contains($0.key) }
        return known.count != before
    }

    /// The current names of the postcards at `uris`, from a fetch's URI→name map.
    static func names(of uris: Set<String>, in cards: [AtprotoFetchedCard]) -> Set<String> {
        Set(cards.filter { uris.contains($0.uri) }.map(\.name))
    }

    /// `cards` narrowed to the new ones, by name.
    static func onlyNew(_ cards: [CardSummary], names: Set<String>) -> [CardSummary] {
        cards.filter { names.contains($0.name) }
    }
}

extension AtmosphereCache {
    /// Whether a followed collection is fetched again in the background, without being opened:
    /// only a complete copy its record has moved on from, and never in Low Data Mode. Go's
    /// networking ignores Low Data Mode, so this is all that keeps such a fetch off a constrained
    /// network; opening the collection fetches it whatever the network.
    static func refetchesInBackground(recordCID: String, sidecar: AtprotoCollectionSidecar?, isLowDataMode: Bool) -> Bool {
        !isLowDataMode && isComplete(sidecar: sidecar) && needsFetch(isCached: true, recordCID: recordCID, sidecar: sidecar)
    }
}
