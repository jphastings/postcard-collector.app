import Foundation
import Observation
import WatchConnectivity

/// The watch's whole data layer: a `WCSessionDelegate` that receives the iPhone's catalog
/// (pushed as the application context) and pinned collections' files (sent with
/// `transferFile`), caching both to disk so the app has something to show with no phone
/// present. watchOS can't open iCloud Drive documents, so unlike the abandoned
/// `CloudLibrary` design this never touches iCloud itself — see `WatchRelay` for the wire
/// contract with the iPhone's (iOS-only) relay.
///
/// WCSession's delegate callbacks fire on a private background queue, but `catalog`,
/// `isPhoneReachable` and `downloadProgress` are all `@MainActor` state (via the class-wide
/// `@MainActor`/`@Observable`). Every delegate method below is therefore `nonisolated` and
/// hops back with `Task { @MainActor in ... }` before touching that state — this app has a
/// history of heap-corruption crashes from off-main mutation, so there's no shortcut here.
@MainActor
@Observable
final class WatchLibrary: NSObject {
    private(set) var catalog: [WatchCollectionInfo] = []
    private(set) var isPhoneReachable = false
    /// `id` -> 0...1 while a collection's file is in flight (pinning or a Phase 2 live-view
    /// request). `transferUserInfo`/`transferFile` give no incremental progress on the
    /// receiving side, so this is really a "requested, not yet arrived" marker (`0`) cleared
    /// the moment the file lands.
    private(set) var downloadProgress: [String: Double] = [:]
    /// Ids with a file currently cached on disk (pinned or temporary alike). Populated by
    /// scanning the cache directory on init and kept in sync on every cache/evict — this is
    /// what lets a waiting `WatchPostcardScrollView` react the moment a requested file lands.
    private(set) var downloadedIDs: Set<String> = []

    private let pinStore: PinStore
    /// Injected for the main-actor disk methods (test seam). The one `nonisolated` path,
    /// `cacheReceivedFile`, uses `FileManager.default` directly instead — `FileManager`
    /// isn't `Sendable`, so it can't be shared into a `nonisolated` context.
    private let fileManager: FileManager
    /// `URL` is `Sendable`, so this stays readable from the `nonisolated` delegate methods
    /// below; only the mutable, `@Observable` properties above need a main-actor hop.
    private nonisolated let supportDirectory: URL

    init(
        pinStore: PinStore = PinStore(),
        fileManager: FileManager = .default,
        supportDirectory: URL? = nil
    ) {
        self.pinStore = pinStore
        self.fileManager = fileManager
        self.supportDirectory = supportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        super.init()
        restoreCatalog()
        downloadedIDs = scanDownloadedIDs()
        // Self-heal if the temporary cache limit was ever exceeded across a relaunch (e.g. a
        // crash mid-eviction, or a lowered cap in a future build).
        evictTemporaryFilesIfNeeded()
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func isPinned(_ id: String) -> Bool {
        pinStore.isPinned(id)
    }

    func isDownloaded(_ id: String) -> Bool {
        downloadedIDs.contains(id)
    }

    func localFileURL(for id: String) -> URL? {
        let url = cacheURL(for: id)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Pinning keeps a collection's file downloaded (and exempt from eviction) permanently;
    /// unpinning lets it fall back to being a *temporary* file, subject to eviction, rather
    /// than deleting it outright — so unpinning something you're currently viewing doesn't
    /// yank the file out from under you.
    func setPinned(_ pinned: Bool, id: String) {
        pinStore.setPinned(pinned, for: id)
        if pinned {
            // Already cached (e.g. requested for live viewing earlier) — just protect it from
            // eviction, no need to re-request the transfer.
            guard !isDownloaded(id) else { return }
            downloadProgress[id] = 0
            WCSession.default.transferUserInfo([WatchRelay.opKey: WatchRelay.opPin, WatchRelay.idKey: id])
        } else {
            downloadProgress[id] = nil
            if WCSession.default.activationState == .activated {
                WCSession.default.transferUserInfo([WatchRelay.opKey: WatchRelay.opUnpin, WatchRelay.idKey: id])
            }
            evictTemporaryFilesIfNeeded()
        }
    }

    /// Asks the phone for a live (unpinned) view of this collection while reachable. The file
    /// arrives just like a pinned one, but is cached as *temporary* — eligible for eviction
    /// once the temporary cache cap is exceeded — since it was never asked to be kept.
    func requestDownloadIfNeeded(id: String) {
        guard !isDownloaded(id), isPhoneReachable else { return }
        downloadProgress[id] = 0
        WCSession.default.transferUserInfo([WatchRelay.opKey: WatchRelay.opRequest, WatchRelay.idKey: id])
    }

    // MARK: - Disk cache

    private func cacheURL(for id: String) -> URL {
        WatchCacheLayout.cacheURL(for: id, in: supportDirectory)
    }

    private func restoreCatalog() {
        let url = WatchCacheLayout.catalogFileURL(in: supportDirectory)
        guard
            let data = fileManager.contents(atPath: url.path),
            let restored = WatchCacheLayout.decodeCatalog(data)
        else { return }
        catalog = restored
    }

    private func persistCatalog(_ catalog: [WatchCollectionInfo]) {
        guard let data = WatchCacheLayout.encodeCatalog(catalog) else { return }
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: WatchCacheLayout.catalogFileURL(in: supportDirectory), options: .atomic)
    }

    /// Moves a just-received file into the pin cache. Must run synchronously, on whatever
    /// thread WCSession calls the delegate on: `file.fileURL` points at a temporary location
    /// WCSession may reclaim as soon as `session(_:didReceive:)` returns, so — unlike the
    /// `@Observable` state updates, which can wait for the main actor — this can't be
    /// deferred into a `Task`. Returns whether the move succeeded, so the caller knows whether
    /// to record the id as downloaded.
    private nonisolated func cacheReceivedFile(_ file: WCSessionFile, id: String) -> Bool {
        let fileManager = FileManager.default
        let directory = WatchCacheLayout.pinnedCollectionsDirectory(in: supportDirectory)
        let destination = WatchCacheLayout.cacheURL(for: id, in: supportDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: file.fileURL, to: destination)
            return true
        } catch {
            // The row keeps showing "in progress" rather than silently claiming success. A
            // future re-pin, re-request, or relaunch can retry.
            return false
        }
    }

    private func scanDownloadedIDs() -> Set<String> {
        Set(cachedFileURLs().map { $0.deletingPathExtension().lastPathComponent })
    }

    /// Each currently-cached collection's id and file modification date, for feeding into
    /// `WatchCacheLayout.idsToEvict`.
    private func cachedModificationDates() -> [String: Date] {
        var dates: [String: Date] = [:]
        for url in cachedFileURLs() {
            let id = url.deletingPathExtension().lastPathComponent
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            dates[id] = modified ?? .distantPast
        }
        return dates
    }

    private func cachedFileURLs() -> [URL] {
        let directory = WatchCacheLayout.pinnedCollectionsDirectory(in: supportDirectory)
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents.filter { $0.pathExtension == "postcards" }
    }

    /// Evicts the least-recently-modified temporary (unpinned) cached files down to
    /// `WatchCacheLayout.temporaryCacheLimit`. Pinned files are never touched. Call after
    /// anything that could grow the temporary cache (a requested or pinned file arriving) or
    /// shrink the pinned set (an unpin).
    private func evictTemporaryFilesIfNeeded() {
        let evictable = WatchCacheLayout.idsToEvict(
            cachedModificationDates: cachedModificationDates(),
            pinned: pinStore.pinnedKeys
        )
        guard !evictable.isEmpty else { return }
        for id in evictable {
            try? fileManager.removeItem(at: cacheURL(for: id))
            downloadedIDs.remove(id)
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchLibrary: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard
            let data = applicationContext[WatchRelay.catalogKey] as? Data,
            let catalog = WatchCacheLayout.decodeCatalog(data)
        else { return }
        Task { @MainActor in
            self.catalog = catalog
            self.persistCatalog(catalog)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let id = file.metadata?[WatchRelay.fileIdKey] as? String else { return }
        let succeeded = cacheReceivedFile(file, id: id)
        Task { @MainActor in
            self.downloadProgress[id] = nil
            guard succeeded else { return }
            self.downloadedIDs.insert(id)
            self.evictTemporaryFilesIfNeeded()
        }
    }
}
