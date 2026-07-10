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
    /// `id` -> 0...1 while a pinned collection's file is in flight. `transferUserInfo`
    /// gives no incremental progress on the receiving side, so in Phase 1 this is really a
    /// "requested, not yet arrived" marker (`0`) cleared the moment the file lands.
    private(set) var downloadProgress: [String: Double] = [:]

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
        fileManager.fileExists(atPath: cacheURL(for: id).path)
    }

    func localFileURL(for id: String) -> URL? {
        let url = cacheURL(for: id)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func setPinned(_ pinned: Bool, id: String) {
        pinStore.setPinned(pinned, for: id)
        if pinned {
            downloadProgress[id] = 0
            WCSession.default.transferUserInfo([WatchRelay.opKey: WatchRelay.opPin, WatchRelay.idKey: id])
        } else {
            downloadProgress[id] = nil
            try? fileManager.removeItem(at: cacheURL(for: id))
            if WCSession.default.activationState == .activated {
                WCSession.default.transferUserInfo([WatchRelay.opKey: WatchRelay.opUnpin, WatchRelay.idKey: id])
            }
        }
    }

    /// Phase 2 stub: the phone doesn't yet act on `opRequest`, but the watch can already
    /// ask for a live (unpinned) view whenever it's reachable.
    func requestDownloadIfNeeded(id: String) {
        guard !isDownloaded(id), isPhoneReachable else { return }
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
    /// deferred into a `Task`.
    private nonisolated func cacheReceivedFile(_ file: WCSessionFile, id: String) {
        let fileManager = FileManager.default
        let directory = WatchCacheLayout.pinnedCollectionsDirectory(in: supportDirectory)
        let destination = WatchCacheLayout.cacheURL(for: id, in: supportDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: file.fileURL, to: destination)
        } catch {
            // Leave downloadProgress[id] as-is: the row keeps showing "in progress" rather
            // than silently claiming success. A future re-pin or relaunch can retry.
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
        cacheReceivedFile(file, id: id)
        Task { @MainActor in
            self.downloadProgress[id] = nil
        }
    }
}
