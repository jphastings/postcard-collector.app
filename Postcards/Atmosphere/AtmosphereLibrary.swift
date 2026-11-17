import Foundation
import Observation
import os

private let logger = Logger(subsystem: "org.dotpostcard.collector", category: "Atmosphere")

/// The signed-in Atmosphere accounts' collections: each account's listing, and the cached copy
/// of every collection that's been opened (see `AtmosphereCache`).
@MainActor
@Observable
final class AtmosphereLibrary {
    /// Each signed-in account's collections, by DID: the last good listing, kept when a later
    /// one fails. Absent until one has loaded.
    private(set) var collections: [String: [AtprotoCollection]] = [:]
    /// Why each account's latest listing failed, by DID.
    private(set) var listingErrors: [String: String] = [:]
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

    private var signedIn: [String] = []
    private var isReloading = false
    private var reloadThrottle = ReloadThrottle()
    private let root: URL

    init(root: URL = AtmosphereCache.defaultRoot) {
        self.root = root
    }

    /// Lists every signed-in account's collections. Accounts that are no longer signed in are
    /// forgotten, cache and all.
    func reload(signedIn dids: [String]) async {
        for did in signedIn where !dids.contains(did) {
            await forget(did)
        }
        signedIn = dids
        for did in dids where collections[did] == nil {
            collections[did] = savedListing(for: did)
        }
        refreshCachedPaths()
        await findPartialDownloads()

        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        var listed: Set<String> = []
        // Re-read each time round, so an account signed in meanwhile is listed too.
        while let did = signedIn.first(where: { !listed.contains($0) }) {
            listed.insert(did)
            do {
                let fetched = try await GoCore.shared.atprotoCollections(actor: did)
                    .filter { AtmosphereCache.rkey(of: $0.uri) != nil }
                guard signedIn.contains(did) else { continue }
                collections[did] = fetched
                listingErrors[did] = nil
                saveListing(fetched, for: did)
            } catch {
                listingErrors[did] = error.localizedDescription
            }
        }
        refreshCachedPaths()
    }

    func source(for collection: AtprotoCollection, did: String) -> LibrarySource? {
        AtmosphereCache.collectionURL(root: root, did: did, uri: collection.uri).map {
            .atprotoCollection(uri: collection.uri, path: $0.path, displayName: collection.title)
        }
    }

    /// Every browsable collection of the signed-in accounts, partial ones included, for
    /// "All collections".
    var cachedCollectionPaths: [String] {
        signedIn.flatMap { did in
            (collections[did] ?? []).compactMap { source(for: $0, did: did)?.path }
        }
        .filter(cachedPaths.contains)
    }

    /// Downloads the collection the first time it's opened, or resumes a partial download; once
    /// complete, fetches it again only when its record has changed. Cards land in the file one by
    /// one, so it can be browsed from the first (see `progress` and `generation`).
    ///
    /// Low Data Mode: fetching collection contents only ever happens here, because the user opened
    /// the collection. Never start one pre-emptively (a background resume or refresh of collections
    /// that aren't open) while `NWPathMonitor` reports the path `isConstrained`.
    func open(uri: String) async {
        guard !fetching.contains(uri), case let (did, collection)? = listed(uri),
              let url = AtmosphereCache.collectionURL(root: root, did: did, uri: uri)
        else { return }
        fetching.insert(uri)
        defer { fetching.remove(uri) }

        let isComplete = completePaths.contains(url.path)
        var recordCID = collection.cid
        if isComplete {
            guard let latest = try? await GoCore.shared.atprotoCollection(uri: uri),
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
            try? AtmosphereCache.writeSidecar(AtprotoCollectionSidecar(cid: recordCID, cards: cards), forCollectionAt: url)
            guard signedIn.contains(did) else {
                try? FileManager.default.removeItem(at: AtmosphereCache.accountDirectory(root: root, did: did))
                return
            }
            completePaths.insert(url.path)
            cachedPaths.insert(url.path)
        } catch {
            reporter.finish()
            await consumer.value
            // Quietly: the sidebar row says so, and whatever arrived stays browsable.
            logger.error("Downloading \(uri, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            downloadErrors[uri] = error.localizedDescription
        }
        reloadNow()
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

    /// How many postcards the listing says the collection at `uri` holds.
    func cardCount(of uri: String) -> Int? {
        listed(uri)?.collection.cardCount
    }

    private func listed(_ uri: String) -> (did: String, collection: AtprotoCollection)? {
        for did in signedIn {
            if let collection = collections[did]?.first(where: { $0.uri == uri }) { return (did, collection) }
        }
        return nil
    }

    private func forget(_ did: String) async {
        let directory = AtmosphereCache.accountDirectory(root: root, did: did)
        // Every file, not just browsable ones: `findPartialDownloads` opens empty ones too.
        for path in collectionURLs(of: [did]).map(\.path) {
            await GoCore.shared.invalidateSource(at: path)
        }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: AtmosphereCache.listingURL(root: root, did: did))
        collections[did] = nil
        listingErrors[did] = nil
        refreshCachedPaths()
    }

    private func collectionURLs(of dids: [String]) -> [URL] {
        dids.flatMap { did in
            (collections[did] ?? []).compactMap { AtmosphereCache.collectionURL(root: root, did: did, uri: $0.uri) }
        }
    }

    private func refreshCachedPaths() {
        let onDisk = collectionURLs(of: signedIn).filter { FileManager.default.fileExists(atPath: $0.path) }
        completePaths = Set(onDisk.filter { AtmosphereCache.isComplete(sidecar: AtmosphereCache.readSidecar(forCollectionAt: $0)) }.map(\.path))
        cachedPaths = completePaths.union(cachedPaths.intersection(onDisk.map(\.path)))
    }

    /// Adds the partial downloads (a fetch that failed or was cut short) that hold a card. Running
    /// fetches report their own cards, and their files may not be readable yet.
    private func findPartialDownloads() async {
        let running = Set(fetching.compactMap { uri in listed(uri).flatMap { AtmosphereCache.collectionURL(root: root, did: $0.did, uri: uri)?.path } })
        for path in collectionURLs(of: signedIn).map(\.path)
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
}
