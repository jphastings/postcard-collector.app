import Foundation
import Network
import Observation
import os

private let logger = Logger(subsystem: "org.dotpostcard.collector", category: "Atmosphere")

/// The signed-in Atmosphere accounts' collections and the collections they follow: each account's
/// listing and follows, and the cached copy of every collection that's been opened (see
/// `AtmosphereCache`). Everything about a collection is keyed by its at-uri, so one followed by
/// several accounts, or owned by one and followed by another, has one record, one cached file and
/// one download.
@MainActor
@Observable
final class AtmosphereLibrary {
    /// Each signed-in account's collections, by DID: the last good listing, kept when a later
    /// one fails. Absent until one has loaded.
    private(set) var collections: [String: [AtprotoCollection]] = [:]
    /// Why each account's latest listing failed, by DID.
    private(set) var listingErrors: [String: String] = [:]
    /// Each signed-in account's follows, by DID: the last good list, kept when a later one fails.
    /// Absent until one has loaded.
    private(set) var follows: [String: [AtprotoFollow]] = [:]
    /// Followed collections' records, by at-uri: the last good read of each.
    private var followedRecords: [String: AtprotoCollection] = [:]
    /// Followed collections' owners' handles, by DID.
    private var ownerHandles: [String: String] = [:]
    /// Why a collection's latest fetch failed, by at-uri.
    private(set) var downloadErrors: [String: String] = [:]
    /// Collections being opened (their record checked, and fetched if need be), by at-uri.
    private(set) var fetching: Set<String> = []
    /// How far each running fetch has got, by at-uri.
    private(set) var progress: [String: CollectionFetchProgress] = [:]
    /// Collection files that can be browsed: complete ones, and partial ones holding a card.
    private(set) var cachedPaths: Set<String> = []
    /// Collection files a fetch has finished (see `AtmosphereCache.isComplete`).
    private(set) var completePaths: Set<String> = []
    /// Bumped as a fetch writes cards into a cached file, so open views reload it.
    private(set) var generation = 0
    private var newPostcardState: AtmosphereNewPostcards
    /// Each complete cached collection's postcards and their names, by collection at-uri, from its
    /// sidecar.
    private var fetchedCards: [String: [AtprotoFetchedCard]] = [:]
    private var isLowDataMode = false

    private var signedIn: [String] = []
    private var isReloading = false
    private var reloadThrottle = ReloadThrottle()
    private let root: URL
    private let newPostcardsURL: URL
    private let pathMonitor = NWPathMonitor()

    init(root: URL = AtmosphereCache.defaultRoot, newPostcardsURL: URL = AtmosphereNewPostcards.defaultURL) {
        self.root = root
        self.newPostcardsURL = newPostcardsURL
        newPostcardState = (try? Data(contentsOf: newPostcardsURL))
            .flatMap { try? JSONDecoder().decode(AtmosphereNewPostcards.self, from: $0) } ?? AtmosphereNewPostcards()
        if let data = try? Data(contentsOf: AtmosphereCache.followingURL(root: root)),
           let saved = try? JSONDecoder().decode(AtmosphereFollowingSnapshot.self, from: data) {
            follows = saved.follows
            followedRecords = saved.records
            ownerHandles = saved.handles
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.isLowDataMode = path.isConstrained }
        }
        pathMonitor.start(queue: .main)
    }

    /// Lists every signed-in account's collections and follows, and reads each followed collection's
    /// record once. Accounts that are no longer signed in are forgotten, along with the cached
    /// collections no remaining account owns or follows.
    func reload(signedIn dids: [String]) async {
        let leaving = signedIn.filter { !dids.contains($0) }
        let leftBehind = leaving.flatMap { did in (collections[did] ?? []).map(\.uri) + (follows[did] ?? []).map(\.subject) }
        signedIn = dids
        for did in leaving {
            try? FileManager.default.removeItem(at: AtmosphereCache.listingURL(root: root, did: did))
            collections[did] = nil
            listingErrors[did] = nil
            follows[did] = nil
        }
        if !leaving.isEmpty { followingChanged() }
        for did in dids where collections[did] == nil {
            collections[did] = savedListing(for: did)
        }
        await dropCaches(of: leftBehind)
        refreshCachedPaths()
        await findPartialDownloads()

        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        var refreshed: Set<String> = []
        // Re-read each time round, so an account signed in meanwhile is refreshed too.
        repeat {
            while let did = signedIn.first(where: { !refreshed.contains($0) }) {
                refreshed.insert(did)
                await refreshListing(of: did)
                await refreshFollows(of: did)
            }
            await refreshFollowedRecords(missingOnly: false)
        } while signedIn.contains { !refreshed.contains($0) }
        refreshCachedPaths()
    }

    /// After following or unfollowing as `did`.
    func reloadFollows(of did: String) async {
        await refreshFollows(of: did)
        await refreshFollowedRecords(missingOnly: true)
        refreshCachedPaths()
    }

    private func refreshListing(of did: String) async {
        do {
            let fetched = try await GoCore.shared.atprotoCollections(actor: did)
                .filter { AtmosphereCache.rkey(of: $0.uri) != nil }
            guard signedIn.contains(did) else { return }
            collections[did] = fetched
            listingErrors[did] = nil
            saveListing(fetched, for: did)
        } catch {
            listingErrors[did] = error.localizedDescription
        }
    }

    private func refreshFollows(of did: String) async {
        do {
            let fetched = try await GoCore.shared.atprotoFollows(actor: did)
            guard signedIn.contains(did) else { return }
            let before = (follows[did] ?? []).map(\.subject)
            follows[did] = fetched
            followingChanged()
            await dropCaches(of: before)
        } catch {
            logger.error("Listing \(did, privacy: .public)'s follows failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads each followed collection's record (once, however many accounts follow it) and its
    /// owner's handle, which is all that's fetched in Low Data Mode. Otherwise a downloaded
    /// collection whose record has changed is fetched again in the background, so it's up to date
    /// when opened.
    private func refreshFollowedRecords(missingOnly: Bool) async {
        let subjects = followedSubjects
        for uri in subjects where ownListing(of: uri) == nil && !(missingOnly && followedRecords[uri] != nil) {
            do {
                let record = try await GoCore.shared.atprotoCollection(uri: uri)
                followedRecords[uri] = record
                if let url = AtmosphereCache.collectionURL(root: root, uri: uri),
                   AtmosphereCache.refetchesInBackground(
                       recordCID: record.cid, sidecar: AtmosphereCache.readSidecar(forCollectionAt: url), isLowDataMode: isLowDataMode
                   ) {
                    Task { await fetch(uri: uri, latest: record) }
                }
            } catch {
                logger.error("Reading followed \(uri, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for owner in Set(subjects.compactMap(AtmosphereCache.owner(of:))) where !(missingOnly && ownerHandles[owner] != nil) {
            if let handle = try? await IdentityResolver.resolve(owner).handle { ownerHandles[owner] = handle }
        }
        followingChanged()
    }

    func source(for collection: AtprotoCollection) -> LibrarySource? {
        AtmosphereCache.collectionURL(root: root, uri: collection.uri).map {
            .atprotoCollection(uri: collection.uri, path: $0.path, displayName: collection.title)
        }
    }

    /// The collections `did` follows, in the order it followed them, whose records have been read.
    func collections(followedBy did: String) -> [AtprotoCollection] {
        AtmosphereFollowing.subjects(followedBy: [follows[did] ?? []]).compactMap(listed)
    }

    /// The handle of the account whose collection is at `uri`, or its DID until that's resolved.
    func ownerHandle(of uri: String) -> String? {
        AtmosphereCache.owner(of: uri).map { ownerHandles[$0] ?? $0 }
    }

    /// Where every collection the signed-in accounts own or follow is (or would be) cached.
    var collectionPaths: Set<String> {
        Set(knownURLs.map(\.path))
    }

    /// Every browsable collection the signed-in accounts own or follow, partial ones included, for
    /// "All collections".
    var cachedCollectionPaths: [String] {
        knownURLs.map(\.path).filter(cachedPaths.contains)
    }

    /// Downloads the collection the first time it's opened, or resumes a partial download; once
    /// complete, fetches it again only when its record has changed. Cards land in the file one by
    /// one, so it can be browsed from the first (see `progress` and `generation`).
    ///
    /// Opening a followed collection sees its unseen new postcards (see `AtmosphereNewPostcards`).
    ///
    /// Low Data Mode: fetching collection contents only happens here, because the user opened the
    /// collection, or in the background when `AtmosphereCache.refetchesInBackground` allows it.
    func open(uri: String) async {
        if isFollowedOnly(uri), let record = followedRecords[uri],
           newPostcardState.open(uri, postcards: record.postcards, at: .now) {
            saveNewPostcards()
        }
        await fetch(uri: uri)
    }

    /// `latest` is the collection's record, when it's just been read.
    private func fetch(uri: String, latest: AtprotoCollection? = nil) async {
        // A fetch already running for this uri, from whichever row, is the one to show.
        guard !fetching.contains(uri), let collection = listed(uri),
              let url = AtmosphereCache.collectionURL(root: root, uri: uri)
        else { return }
        fetching.insert(uri)
        defer { fetching.remove(uri) }

        let isComplete = completePaths.contains(url.path)
        var recordCID = collection.cid
        if isComplete {
            guard let latest = await latestRecord(latest, uri: uri),
                  AtmosphereCache.needsFetch(isCached: true, recordCID: latest.cid, sidecar: AtmosphereCache.readSidecar(forCollectionAt: url))
            else { return }
            recordCID = latest.cid
        }

        downloadErrors[uri] = nil
        progress[uri] = CollectionFetchProgress()
        let (cardsAdded, reporter) = AsyncStream.makeStream(of: CollectionFetchProgress.self)
        // Go reports from its own threads; the stream carries each card here, in order.
        let consumer = Task {
            for await update in cardsAdded {
                cardAdded(update, uri: uri, path: url.path, isComplete: isComplete)
            }
        }
        defer { progress[uri] = nil }

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let cards = try await fetchRetryingOnce(uri: uri, to: url.path) { done, total in
                reporter.yield(CollectionFetchProgress(done: done, total: total))
            }
            reporter.finish()
            await consumer.value
            // Without it, the next open fetches again.
            let sidecar = AtprotoCollectionSidecar(cid: recordCID, cards: cards)
            try? AtmosphereCache.writeSidecar(sidecar, forCollectionAt: url)
            guard isWanted(uri) else {
                await removeCache(of: uri)
                return
            }
            completePaths.insert(url.path)
            cachedPaths.insert(url.path)
            completed(sidecar, uri: uri)
        } catch {
            reporter.finish()
            await consumer.value
            // Quietly: the sidebar row says so, and whatever arrived stays browsable.
            logger.error("Downloading \(uri, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            downloadErrors[uri] = error.localizedDescription
        }
        reloadNow()
    }

    private func latestRecord(_ latest: AtprotoCollection?, uri: String) async -> AtprotoCollection? {
        if let latest { return latest }
        return try? await GoCore.shared.atprotoCollection(uri: uri)
    }

    /// A failed download keeps the cards it committed, so trying again straight away resumes
    /// cheaply; only a second failure is worth showing.
    private func fetchRetryingOnce(
        uri: String, to path: String, onCard: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [AtprotoFetchedCard] {
        do {
            return try await GoCore.shared.fetchAtprotoCollection(uri: uri, to: path, onCard: onCard)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("Downloading \(uri, privacy: .public) failed, resuming: \(error.localizedDescription, privacy: .public)")
            return try await GoCore.shared.fetchAtprotoCollection(uri: uri, to: path, onCard: onCard)
        }
    }

    private func cardAdded(_ update: CollectionFetchProgress, uri: String, path: String, isComplete: Bool) {
        progress[uri] = update
        if AtmosphereCache.isBrowsable(isComplete: isComplete, cardCount: update.done) {
            cachedPaths.insert(path)
        }
        guard let delay = reloadThrottle.schedule(at: ProcessInfo.processInfo.systemUptime) else { return }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            reloadNow()
        }
    }

    private func reloadNow() {
        reloadThrottle.didReload(at: ProcessInfo.processInfo.systemUptime)
        generation += 1
    }

    /// Whether the followed collection at `uri` has postcards that arrived since it was last opened.
    func hasUnseenPostcards(_ uri: String) -> Bool {
        guard isFollowedOnly(uri), let record = followedRecords[uri] else { return false }
        return !newPostcardState.unseen(in: uri, postcards: record.postcards).isEmpty
    }

    /// The postcards in the collection at `uri` that are new now, by at-uri.
    func newPostcards(in uri: String) -> Set<String> {
        newPostcardState.new(in: uri, at: .now)
    }

    /// The current names of the postcards in the collection at `uri` that are new now; empty for
    /// any that haven't downloaded yet.
    func newPostcardNames(in uri: String) -> Set<String> {
        AtmosphereNewPostcards.names(of: newPostcards(in: uri), in: fetchedCards[uri] ?? [])
    }

    /// How many postcards the listing says the collection at `uri` holds.
    func cardCount(of uri: String) -> Int? {
        listed(uri)?.cardCount
    }

    /// The record of a collection a signed-in account owns or follows.
    private func listed(_ uri: String) -> AtprotoCollection? {
        ownListing(of: uri) ?? (followedSubjects.contains(uri) ? followedRecords[uri] : nil)
    }

    private func ownListing(of uri: String) -> AtprotoCollection? {
        for did in signedIn {
            if let collection = collections[did]?.first(where: { $0.uri == uri }) { return collection }
        }
        return nil
    }

    private var followedSubjects: [String] {
        AtmosphereFollowing.subjects(followedBy: signedIn.map { follows[$0] ?? [] })
    }

    /// New postcards are only looked for in collections the signed-in accounts follow but don't own.
    private func isFollowedOnly(_ uri: String) -> Bool {
        ownListing(of: uri) == nil && followedSubjects.contains(uri)
    }

    /// Every collection the signed-in accounts own or follow, once each.
    private var knownURIs: [String] {
        var seen: Set<String> = []
        return (signedIn.flatMap { (collections[$0] ?? []).map(\.uri) } + followedSubjects)
            .filter { seen.insert($0).inserted }
    }

    private var knownURLs: [URL] {
        knownURIs.compactMap { AtmosphereCache.collectionURL(root: root, uri: $0) }
    }

    private func isWanted(_ uri: String) -> Bool {
        AtmosphereCache.keepsCache(of: uri, signedIn: Set(signedIn), followed: Set(followedSubjects))
    }

    /// Deletes the cached copies among `uris` that no signed-in account owns or follows any more.
    private func dropCaches(of uris: [String]) async {
        // An account whose follows haven't loaded yet may follow any of them.
        guard signedIn.allSatisfy({ follows[$0] != nil }) else { return }
        for uri in Set(uris) where !fetching.contains(uri) && !isWanted(uri) {
            await removeCache(of: uri)
        }
    }

    private func removeCache(of uri: String) async {
        guard let url = AtmosphereCache.collectionURL(root: root, uri: uri) else { return }
        // Even an unbrowsable file: `findPartialDownloads` opens empty ones too.
        await GoCore.shared.invalidateSource(at: url.path)
        let directory = url.deletingLastPathComponent()
        let file = url.lastPathComponent
        let sidecar = AtmosphereCache.sidecarURL(forCollectionAt: url).lastPathComponent
        // SQLite's -wal/-shm/-journal companions go with it.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name == file || name.hasPrefix("\(file)-") || name == sidecar {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: directory)
        }
        cachedPaths.remove(url.path)
        completePaths.remove(url.path)
    }

    private func refreshCachedPaths() {
        var onDisk: Set<String> = []
        var complete: Set<String> = []
        for uri in knownURIs {
            guard let url = AtmosphereCache.collectionURL(root: root, uri: uri), FileManager.default.fileExists(atPath: url.path) else { continue }
            onDisk.insert(url.path)
            if let sidecar = AtmosphereCache.readSidecar(forCollectionAt: url), AtmosphereCache.isComplete(sidecar: sidecar) {
                complete.insert(url.path)
                completed(sidecar, uri: uri)
            }
        }
        completePaths = complete
        cachedPaths = complete.union(cachedPaths.intersection(onDisk))
    }

    /// Takes in what a complete download of the collection at `uri` holds.
    private func completed(_ sidecar: AtprotoCollectionSidecar, uri: String) {
        fetchedCards[uri] = sidecar.cards
        if isFollowedOnly(uri), newPostcardState.downloaded(uri, postcards: sidecar.cards.map(\.uri)) {
            saveNewPostcards()
        }
    }

    private func saveNewPostcards() {
        try? FileManager.default.createDirectory(at: newPostcardsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(newPostcardState).write(to: newPostcardsURL, options: .atomic)
    }

    /// Adds the partial downloads (a fetch that failed or was cut short) that hold a card. Running
    /// fetches report their own cards, and their files may not be readable yet.
    private func findPartialDownloads() async {
        let running = Set(fetching.compactMap { AtmosphereCache.collectionURL(root: root, uri: $0)?.path })
        for path in knownURLs.map(\.path)
        where !cachedPaths.contains(path) && !running.contains(path) && FileManager.default.fileExists(atPath: path) {
            let count = (try? await GoCore.shared.cardSummaries(inCollectionAt: path).count) ?? 0
            if AtmosphereCache.isBrowsable(isComplete: false, cardCount: count), FileManager.default.fileExists(atPath: path) {
                cachedPaths.insert(path)
            }
        }
    }

    private func savedListing(for did: String) -> [AtprotoCollection]? {
        guard let data = try? Data(contentsOf: AtmosphereCache.listingURL(root: root, did: did)) else { return nil }
        return try? JSONDecoder().decode([AtprotoCollection].self, from: data)
    }

    private func saveListing(_ listing: [AtprotoCollection], for did: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(listing).write(to: AtmosphereCache.listingURL(root: root, did: did), options: .atomic)
    }

    /// Forgets the records and handles of collections no longer followed, and saves the rest.
    private func followingChanged() {
        let subjects = Set(followedSubjects)
        followedRecords = followedRecords.filter { subjects.contains($0.key) }
        if newPostcardState.keepOnly(subjects) { saveNewPostcards() }
        let owners = Set(subjects.compactMap(AtmosphereCache.owner(of:)))
        ownerHandles = ownerHandles.filter { owners.contains($0.key) }
        let snapshot = AtmosphereFollowingSnapshot(
            follows: follows.filter { signedIn.contains($0.key) }, records: followedRecords, handles: ownerHandles
        )
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: AtmosphereCache.followingURL(root: root), options: .atomic)
    }
}
