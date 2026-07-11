import Foundation
import Postcards

/// Errors surfaced by `GoCore`, wrapping failures from the Go core or its JSON payloads.
enum GoCoreError: LocalizedError {
    case openFailed(String)
    case missingData(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "Couldn't open \(path)."
        case .missingData(let name):
            return "No data is available for \"\(name)\"."
        case .invalidJSON(let context):
            return "The postcard core returned data the app couldn't understand (\(context))."
        }
    }
}

/// Actor wrapping the generated `Appcore` Objective-C API (see
/// `Frameworks/Postcards.xcframework`). Every method here does blocking file/SQLite I/O,
/// so callers must `await` them; being an `actor` guarantees that work happens off the
/// main thread (Swift concurrency schedules actor bodies on its own executor) while
/// serializing access to the underlying Go handles, which aren't safe to call concurrently.
///
/// gobind's generated Objective-C methods take a trailing `NSError **` but don't follow
/// the exact Cocoa convention Swift auto-bridges into `throws` (no `NS_SWIFT_NAME`, and
/// the free functions in particular import as plain functions with an `NSErrorPointer`
/// parameter) — so every call here goes through `GoCore.call`, which does that manual
/// error-pointer dance once and re-throws as a normal Swift error.
actor GoCore {
    static let shared = GoCore()

    private var collections: [String: AppcoreCollection] = [:]
    private var cardFiles: [String: AppcoreCardFile] = [:]
    // AppcoreNewLibrary just allocates an empty Go struct; it has no failure mode.
    private let library = AppcoreNewLibrary()!

    private static let decoder = JSONDecoder()

    /// Calls a gobind-generated Objective-C method/function that reports failure via a
    /// trailing `NSError **` out-parameter, converting that into a thrown Swift error.
    private static func call<T>(_ body: (NSErrorPointer) -> T) throws -> T {
        var nsError: NSError?
        let result = body(&nsError)
        if let nsError {
            throw nsError
        }
        return result
    }

    // MARK: - Collections

    /// Opens (or reuses a cached handle to) the collection at `path`.
    private func collection(at path: String) throws -> AppcoreCollection {
        if let existing = collections[path] { return existing }
        guard let opened = try Self.call({ AppcoreOpenCollection(path, $0) }) else {
            throw GoCoreError.openFailed(path)
        }
        collections[path] = opened
        return opened
    }

    /// The collection's user-set title, or "" if none has been set.
    func title(ofCollectionAt path: String) throws -> String {
        let col = try collection(at: path)
        return try Self.call({ col.title($0) })
    }

    /// Every card in the collection, in storage order.
    func cardSummaries(inCollectionAt path: String) throws -> [CardSummary] {
        let col = try collection(at: path)
        let json = try Self.call({ col.listJSON($0) })
        return try Self.decode([CardSummary].self, from: json, context: "listing \(path)")
    }

    /// Full-text search within a single collection, best matches first.
    func search(inCollectionAt path: String, query: String) throws -> [SearchResult] {
        let col = try collection(at: path)
        let json = try Self.call({ col.searchJSON(query, error: $0) })
        return try Self.decode([SearchResult].self, from: json, context: "searching \(path)")
    }

    /// Structured (person/country/date) search within a single collection, best matches
    /// first.
    func searchFiltered(inCollectionAt path: String, filter: SearchQuery) throws -> [SearchResult] {
        let col = try collection(at: path)
        let json = try Self.call({ col.searchFilteredJSON(filter.filterJSON ?? "", error: $0) })
        return try Self.decode([SearchResult].self, from: json, context: "searching \(path)")
    }

    /// Every distinct person (sender/recipient/collector) across the collection's cards,
    /// each annotated with which role(s) they've held — powers search-token suggestions.
    /// NOTE: calls the gobind-generated `peopleJSON`, which lands alongside this method in
    /// the framework rebuild; this won't compile against an older `Postcards.xcframework`.
    func people(inCollectionAt path: String) throws -> [PersonRef] {
        let col = try collection(at: path)
        let json = try Self.call({ col.peopleJSON($0) })
        return try Self.decode([PersonRef].self, from: json, context: "listing people in \(path)")
    }

    /// The full metadata record for a card in a collection.
    func metadata(forCard name: String, inCollectionAt path: String) throws -> PostcardMetadata {
        let col = try collection(at: path)
        let json = try Self.call({ col.cardMetaJSON(name, error: $0) })
        return try Self.decode(PostcardMetadata.self, from: json, context: "reading metadata for \(name)")
    }

    /// The pre-generated JPEG thumbnail of a card's front image.
    func thumbnail(forCard name: String, inCollectionAt path: String) throws -> Data {
        try collection(at: path).thumbnail(name)
    }

    /// The raw, untouched bytes of a card's stored (combined front+back) web-format file.
    func image(forCard name: String, inCollectionAt path: String) throws -> Data {
        try collection(at: path).cardImage(name)
    }

    // MARK: - Bare card files

    /// Opens (or reuses a cached handle to) the bare `.postcard.*` file at `path`.
    private func cardFile(at path: String) throws -> AppcoreCardFile {
        if let existing = cardFiles[path] { return existing }
        guard let opened = try Self.call({ AppcoreOpenCardFile(path, $0) }) else {
            throw GoCoreError.openFailed(path)
        }
        cardFiles[path] = opened
        return opened
    }

    func summary(ofCardFileAt path: String) throws -> CardSummary {
        let cf = try cardFile(at: path)
        let json = try Self.call({ cf.summaryJSON($0) })
        return try Self.decode(CardSummary.self, from: json, context: "reading summary for \(path)")
    }

    func metadata(ofCardFileAt path: String) throws -> PostcardMetadata {
        let cf = try cardFile(at: path)
        let json = try Self.call({ cf.metaJSON($0) })
        return try Self.decode(PostcardMetadata.self, from: json, context: "reading metadata for \(path)")
    }

    func image(ofCardFileAt path: String) throws -> Data {
        try cardFile(at: path).image()
    }

    /// Drops (and closes) any cached handle for the file at `path`. Call before replacing
    /// the file on disk — e.g. re-importing a collection — so later calls reopen the new
    /// contents instead of reading through a stale SQLite handle on the deleted inode.
    func invalidateSource(at path: String) {
        if let collection = collections.removeValue(forKey: path) {
            try? collection.close()
        }
        cardFiles.removeValue(forKey: path)
    }

    // MARK: - CardReference convenience

    /// The raw, untouched bytes of a card's stored (combined front+back) web-format file,
    /// wherever it came from.
    func image(for reference: CardReference) throws -> Data {
        switch reference {
        case .inCollection(let path, let summary):
            return try image(forCard: summary.name, inCollectionAt: path)
        case .bareFile(let path, _):
            return try image(ofCardFileAt: path)
        }
    }

    /// The full metadata record for a card, wherever it came from.
    func metadata(for reference: CardReference) throws -> PostcardMetadata {
        switch reference {
        case .inCollection(let path, let summary):
            return try metadata(forCard: summary.name, inCollectionAt: path)
        case .bareFile(let path, _):
            return try metadata(ofCardFileAt: path)
        }
    }

    // MARK: - Writes

    /// Every write below calls through to a transient, package-level Go function (see
    /// `pkg/appcore/write.go`) that opens the file, makes one change, and closes it again —
    /// entirely independent of this actor's long-lived read handles. Each one invalidates
    /// its own cached handle(s) on success, so the next read reopens against the change;
    /// callers don't need to (and, for cloud-backed paths, should prime the write with
    /// `CloudLibrary.primeForGoCoreWrite(path:)` beforehand — this actor knows nothing
    /// about iCloud).

    /// Sets a collection's stored title.
    func setTitle(_ title: String, ofCollectionAt path: String) throws {
        try Self.call { AppcoreSetCollectionTitle(path, title, $0) }
        invalidateSource(at: path)
    }

    /// Adds a card (raw web-format bytes + its filename) to the collection at `path`,
    /// returning the added card's summary. An invalid or undecodable file errors without
    /// changing the collection.
    @discardableResult
    func addCard(filename: String, data: Data, toCollectionAt path: String) throws -> CardSummary {
        let json = try Self.call { AppcoreAddCardToCollection(path, filename, data, $0) }
        invalidateSource(at: path)
        return try Self.decode(CardSummary.self, from: json, context: "adding a card to \(path)")
    }

    /// Removes the named card from the collection at `path`. Errors if no card with that
    /// name exists.
    func removeCard(named name: String, fromCollectionAt path: String) throws {
        try Self.call { AppcoreRemoveCardFromCollection(path, name, $0) }
        invalidateSource(at: path)
    }

    /// Creates a new, empty collection file at `path` (erroring if it already exists),
    /// optionally setting its title.
    func createCollection(at path: String, title: String = "") throws {
        try Self.call { AppcoreCreateCollection(path, title, $0) }
        invalidateSource(at: path)
    }

    /// Moves a card from one collection to another: copies its raw bytes into `targetPath`
    /// first, and only removes the original from `sourcePath` once that copy has
    /// succeeded — so a failure partway through (e.g. a bad target path) always leaves the
    /// source collection with the card still in it, never with it lost.
    func moveCard(named name: String, filename: String, from sourcePath: String, to targetPath: String) throws {
        let data = try image(forCard: name, inCollectionAt: sourcePath)
        try addCard(filename: filename, data: data, toCollectionAt: targetPath)
        try removeCard(named: name, fromCollectionAt: sourcePath)
    }

    // MARK: - Cross-source library search

    /// Replaces the set of sources the "All collections" search fans out across.
    func setLibrarySources(collections collectionPaths: [String], cardFiles cardFilePaths: [String]) throws {
        let payload = LibrarySourcesPayload(collections: collectionPaths, cards: cardFilePaths)
        let data = try JSONEncoder().encode(payload)
        let json = String(decoding: data, as: UTF8.self)
        try library.setSourcesJSON(json)
    }

    func searchLibrary(query: String) throws -> [LibraryHit] {
        let json = try Self.call({ library.searchJSON(query, error: $0) })
        return try Self.decode([LibraryHit].self, from: json, context: "searching the library")
    }

    /// Structured (person/country/date) search across the library's registered sources.
    func searchLibraryFiltered(filter: SearchQuery) throws -> [LibraryHit] {
        let json = try Self.call({ library.searchFilteredJSON(filter.filterJSON ?? "", error: $0) })
        return try Self.decode([LibraryHit].self, from: json, context: "searching the library")
    }

    /// Every distinct person across the library's registered sources. NOTE: calls the
    /// gobind-generated `peopleJSON`, which lands alongside this method in the framework
    /// rebuild; this won't compile against an older `Postcards.xcframework`.
    func libraryPeople() throws -> [PersonRef] {
        let json = try Self.call({ library.peopleJSON($0) })
        return try Self.decode([PersonRef].self, from: json, context: "listing people in the library")
    }

    /// Searches ONLY the given bare `.postcard.*` files, via a transient Go `Library`
    /// scoped to a cards-only source list — the shared `library`'s cross-source fan-out is
    /// untouched. Exists so Single postcards' search shares the Go core's one definition
    /// of a card's searchable text (descriptions, transcriptions, sender, location, …)
    /// instead of a client-side filter over `CardSummary`'s few fields.
    func searchCardFiles(paths: [String], query: String) throws -> [LibraryHit] {
        let transient = AppcoreNewLibrary()!
        let payload = LibrarySourcesPayload(collections: [], cards: paths)
        let data = try JSONEncoder().encode(payload)
        try transient.setSourcesJSON(String(decoding: data, as: UTF8.self))
        let json = try Self.call({ transient.searchJSON(query, error: $0) })
        return try Self.decode([LibraryHit].self, from: json, context: "searching bare card files")
    }

    /// Structured (person/country/date) search over the same cards-only source list as
    /// `searchCardFiles`.
    func searchCardFilesFiltered(paths: [String], filter: SearchQuery) throws -> [LibraryHit] {
        let transient = AppcoreNewLibrary()!
        let payload = LibrarySourcesPayload(collections: [], cards: paths)
        let data = try JSONEncoder().encode(payload)
        try transient.setSourcesJSON(String(decoding: data, as: UTF8.self))
        let json = try Self.call({ transient.searchFilteredJSON(filter.filterJSON ?? "", error: $0) })
        return try Self.decode([LibraryHit].self, from: json, context: "searching bare card files")
    }

    // MARK: - JSON

    private static func decode<T: Decodable>(_ type: T.Type, from json: String, context: String) throws -> T {
        guard let data = json.data(using: .utf8) else {
            throw GoCoreError.invalidJSON(context)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw GoCoreError.invalidJSON("\(context): \(error.localizedDescription)")
        }
    }
}

private struct LibrarySourcesPayload: Encodable {
    var collections: [String]
    var cards: [String]
}
