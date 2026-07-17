import Foundation

/// Autocomplete corpus for "Create a Postcard"'s From/To/Catalogued-by fields: every distinct
/// person from the local library plus every downloaded iCloud collection, deduped and cached
/// to disk so suggestions appear instantly (and offline) on the next launch — refreshed quietly
/// once per "Create a Postcard" appearance (see `CreatePostcardForm`), never blocking the form.
@MainActor
@Observable
final class PeopleDirectory {
    private(set) var people: [PersonRef] = []

    private let cacheFileURL: URL
    private let fetchLibraryPeople: () async throws -> [PersonRef]
    private let primeCloudPath: (String) async throws -> Void
    private let fetchPeopleInCollection: (String) async throws -> [PersonRef]

    nonisolated static var defaultCacheDirectory: URL {
        URL.applicationSupportDirectory
    }

    init(
        cacheDirectory: URL = PeopleDirectory.defaultCacheDirectory,
        fetchLibraryPeople: @escaping () async throws -> [PersonRef] = { try await GoCore.shared.libraryPeople() },
        primeCloudPath: @escaping (String) async throws -> Void = { try await CloudLibrary.primeForGoCore(path: $0) },
        fetchPeopleInCollection: @escaping (String) async throws -> [PersonRef] = { try await GoCore.shared.people(inCollectionAt: $0) }
    ) {
        self.cacheFileURL = cacheDirectory.appendingPathComponent("people-cache.json")
        self.fetchLibraryPeople = fetchLibraryPeople
        self.primeCloudPath = primeCloudPath
        self.fetchPeopleInCollection = fetchPeopleInCollection
        people = Self.loadCache(from: cacheFileURL)
    }

    private static func loadCache(from url: URL) -> [PersonRef] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PersonRef].self, from: data)) ?? []
    }

    /// Refreshes from the library plus every *downloaded* (`.downloadState == .current`) iCloud
    /// collection in `cloudItems`, merges/dedups, and persists the result. `fetchLibraryPeople`
    /// failing (offline, no sources) leaves `people` and the on-disk cache exactly as they were —
    /// a quiet no-op, so the cache keeps serving stale-but-present suggestions. A single
    /// unreachable collection is skipped individually (its people just don't contribute) without
    /// aborting the rest. Any successful refresh REPLACES `people`/the cache wholesale (not a
    /// merge with the old cache) so people removed upstream also disappear from suggestions.
    func refresh(cloudItems: [CloudItem] = []) async {
        guard let libraryPeople = try? await fetchLibraryPeople() else { return }
        var fetched = libraryPeople
        for item in cloudItems where item.isCollection && item.downloadState == .current {
            guard (try? await primeCloudPath(item.path)) != nil else { continue }
            guard let collectionPeople = try? await fetchPeopleInCollection(item.path) else { continue }
            fetched += collectionPeople
        }
        let merged = Self.merge(fetched)
        people = merged
        try? Self.persist(merged, to: cacheFileURL)
    }

    private static func persist(_ people: [PersonRef], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(people)
        try data.write(to: url, options: .atomic)
    }

    /// Dedups by (name, uri) — the same person appearing as e.g. both a library card's sender
    /// and a collection's recipient collapses to one entry whose `roles` is the union of every
    /// role seen for that identity, in first-seen order.
    nonisolated static func merge(_ people: [PersonRef]) -> [PersonRef] {
        struct PersonKey: Hashable {
            var name: String?
            var uri: String?
        }

        var order: [PersonKey] = []
        var roles: [PersonKey: Set<String>] = [:]

        for person in people {
            let key = PersonKey(name: person.name, uri: person.uri)
            if roles[key] == nil {
                roles[key] = []
                order.append(key)
            }
            roles[key]?.formUnion(person.roles)
        }

        return order.map { key in
            PersonRef(name: key.name, uri: key.uri, roles: (roles[key] ?? []).sorted())
        }
    }
}
