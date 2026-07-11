import Foundation
import Observation
import WatchConnectivity

/// The watch's whole data layer: a `WCSessionDelegate` that receives the iPhone's catalog
/// (pushed as the application context) and streams each pinned/requested collection
/// progressively — a manifest naming every card slot, then each card FACE's (front/back, at a
/// screen or zoom tier) ready-to-display image as its own file transfer — caching both to disk
/// so the app has something to show with no phone present. watchOS can't open iCloud Drive
/// documents, so unlike the abandoned `CloudLibrary` design this never touches iCloud itself —
/// see `WatchRelay` for the wire contract with the iPhone's (iOS-only) relay.
///
/// WCSession's delegate callbacks fire on a private background queue, but `catalog`,
/// `isPhoneReachable`, `manifests` and `receivedBlobs` are all `@MainActor` state (via the
/// class-wide `@MainActor`/`@Observable`). Every delegate method below is therefore
/// `nonisolated` and hops back with `Task { @MainActor in ... }` before touching that state —
/// this app has a history of heap-corruption crashes from off-main mutation, so there's no
/// shortcut here.
@MainActor
@Observable
final class WatchLibrary: NSObject {
    private(set) var catalog: [WatchCollectionInfo] = []
    private(set) var isPhoneReachable = false
    /// `id` -> its manifest, once the phone's streamed it. A collection is "openable" (its
    /// slots can be laid out) the moment this lands, even if not every card's blob has
    /// arrived yet.
    private(set) var manifests: [String: [WatchCardMeta]] = [:]
    /// `id` -> the faces (one entry per card/tier/side) whose blob is cached on disk. Faces
    /// arrive in scroll order (screen tier for every card, then zoom tier trailing behind) but
    /// this is a `Set`, not an ordered list, because a card's slot position comes from the
    /// manifest — this only answers "has this particular face landed yet".
    private(set) var receivedBlobs: [String: Set<WatchFaceKey>] = [:]

    private let pinStore: PinStore
    /// Injected for the main-actor disk methods (test seam). The `nonisolated` file-receive
    /// path uses `FileManager.default` directly instead — `FileManager` isn't `Sendable`, so
    /// it can't be shared into a `nonisolated` context.
    private let fileManager: FileManager
    /// `URL` is `Sendable`, so this stays readable from the `nonisolated` delegate methods
    /// below; only the mutable, `@Observable` properties above need a main-actor hop.
    private nonisolated let supportDirectory: URL
    /// An `actor` is inherently `Sendable`, so — like `supportDirectory` above — this is
    /// readable from any isolation domain (the `nonisolated` delegate methods, or a SwiftUI
    /// view) without a main-actor hop; only its own internal state needs synchronizing, which
    /// the actor already does.
    nonisolated let decodedFaceCache = WatchDecodedFaceCache()

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
        restoreCollectionsFromDisk()
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

    func manifest(for id: String) -> [WatchCardMeta]? {
        manifests[id]
    }

    func cardBlobURL(_ id: String, cardName: String, tier: String, side: String) -> URL? {
        let url = WatchCacheLayout.cardBlobURL(id: id, cardName: cardName, tier: tier, side: side, in: supportDirectory)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func hasFaces(id: String, cardName: String, tier: String, hasBack: Bool) -> Bool {
        let blobs = receivedBlobs[id] ?? []
        guard blobs.contains(WatchFaceKey(id: id, cardName: cardName, tier: tier, side: WatchRelay.sideFront)) else { return false }
        guard hasBack else { return true }
        return blobs.contains(WatchFaceKey(id: id, cardName: cardName, tier: tier, side: WatchRelay.sideBack))
    }

    /// Whether the SCREEN tier (front, and back if `hasBack`) has landed for this card — what a
    /// card view waits for before it can render at all.
    func hasScreenFaces(id: String, cardName: String, hasBack: Bool) -> Bool {
        hasFaces(id: id, cardName: cardName, tier: WatchRelay.tierScreen, hasBack: hasBack)
    }

    /// Whether the ZOOM tier has landed — what a zoomed-in card view waits for before swapping
    /// up from the screen tier to the sharper zoom tier.
    func hasZoomFaces(id: String, cardName: String, hasBack: Bool) -> Bool {
        hasFaces(id: id, cardName: cardName, tier: WatchRelay.tierZoom, hasBack: hasBack)
    }

    func expectedCount(for id: String) -> Int? {
        manifests[id]?.count
    }

    func receivedCount(for id: String) -> Int {
        guard let manifest = manifests[id] else { return 0 }
        return manifest.filter { hasScreenFaces(id: id, cardName: $0.name, hasBack: $0.flip != .none) }.count
    }

    /// Whether the collection can be shown as a scroll of slots at all — i.e. its manifest has
    /// landed, even if not every card's image has (those slots show a placeholder meanwhile).
    func isPresent(_ id: String) -> Bool {
        manifests[id] != nil
    }

    /// Whether the collection can open into the postcard view: its manifest has arrived and at
    /// least one card's screen-tier faces are fully cached — so tapping through always shows a
    /// real postcard immediately, rather than a screenful of placeholders.
    func isOpenable(_ id: String) -> Bool {
        guard let manifest = manifests[id] else { return false }
        return manifest.contains { hasScreenFaces(id: id, cardName: $0.name, hasBack: $0.flip != .none) }
    }

    /// Pinning keeps a collection downloaded (and exempt from eviction) permanently; unpinning
    /// lets it fall back to being *temporary*, subject to eviction, rather than deleting it
    /// outright — so unpinning something you're currently viewing doesn't yank it out from
    /// under you.
    func setPinned(_ pinned: Bool, id: String) {
        pinStore.setPinned(pinned, for: id)
        if pinned {
            requestDownloadIfNeeded(id: id)
        } else {
            if WCSession.default.activationState == .activated {
                WCSession.default.transferUserInfo([WatchRelay.opKey: WatchRelay.opUnpin, WatchRelay.idKey: id])
            }
            evictTemporaryFilesIfNeeded()
        }
    }

    /// Asks the phone to stream this collection while reachable — pinning and live-viewing an
    /// unpinned collection both funnel through here; whether the result is later evicted
    /// depends only on `isPinned`, not on which caller asked. A no-op once every card's screen
    /// tier has already landed, so re-navigating to an in-flight or fully-streamed collection
    /// doesn't re-request it — but a present manifest with incomplete screen faces (a stale
    /// v1-format cache, or a stream that got interrupted) DOES re-request, since the phone
    /// re-streaming and overwriting the same deterministic blob paths is harmless and this is
    /// what self-heals those cases.
    func requestDownloadIfNeeded(id: String) {
        guard isPhoneReachable else { return }
        if let manifest = manifests[id] {
            let complete = manifest.allSatisfy { hasScreenFaces(id: id, cardName: $0.name, hasBack: $0.flip != .none) }
            guard !complete else { return }
        }
        WCSession.default.transferUserInfo([WatchRelay.opKey: WatchRelay.opRequest, WatchRelay.idKey: id])
    }

    // MARK: - Disk cache

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

    private func persistManifest(_ manifest: [WatchCardMeta], id: String) {
        guard let data = WatchCacheLayout.encodeManifest(manifest) else { return }
        let directory = WatchCacheLayout.collectionDirectory(id: id, in: supportDirectory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: WatchCacheLayout.manifestURL(id: id, in: supportDirectory), options: .atomic)
    }

    /// Rebuilds `manifests`/`receivedBlobs` on launch by scanning `Collections/` — the source
    /// of truth is always the disk, not anything persisted alongside it, so a crash or forced
    /// quit mid-stream can't leave the in-memory state out of sync with what's actually cached.
    /// Any file in a collection's `cards/` directory whose name doesn't parse as a tier/side
    /// blob (a stale v1-format blob — no `-tier-side` suffix) is deleted outright rather than
    /// left to be misattributed.
    private func restoreCollectionsFromDisk() {
        let root = WatchCacheLayout.collectionsDirectory(in: supportDirectory)
        let ids = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for id in ids {
            if
                let data = fileManager.contents(atPath: WatchCacheLayout.manifestURL(id: id, in: supportDirectory).path),
                let manifest = WatchCacheLayout.decodeManifest(data)
            {
                manifests[id] = manifest
            }
            let cardsDirectory = WatchCacheLayout.cardsDirectory(id: id, in: supportDirectory)
            let cardFileNames = (try? fileManager.contentsOfDirectory(atPath: cardsDirectory.path)) ?? []
            var keys: Set<WatchFaceKey> = []
            for fileName in cardFileNames {
                if let components = WatchCacheLayout.cardBlobComponents(fromSafeFileName: fileName) {
                    keys.insert(WatchFaceKey(id: id, cardName: components.cardName, tier: components.tier, side: components.side))
                } else {
                    try? fileManager.removeItem(at: cardsDirectory.appendingPathComponent(fileName))
                }
            }
            if !keys.isEmpty {
                receivedBlobs[id] = keys
            }
        }
    }

    /// Moves a just-received card face blob into its collection's `cards/` directory. Must run
    /// synchronously, on whatever thread WCSession calls the delegate on: `file.fileURL`
    /// points at a temporary location WCSession may reclaim as soon as
    /// `session(_:didReceive:)` returns, so — unlike the `@Observable` state updates, which
    /// can wait for the main actor — this can't be deferred into a `Task`. Returns whether the
    /// move succeeded, so the caller knows whether to record the face as received.
    private nonisolated func cacheReceivedCardFile(_ file: WCSessionFile, id: String, cardName: String, tier: String, side: String) -> Bool {
        let fileManager = FileManager.default
        let cardsDirectory = WatchCacheLayout.cardsDirectory(id: id, in: supportDirectory)
        let destination = WatchCacheLayout.cardBlobURL(id: id, cardName: cardName, tier: tier, side: side, in: supportDirectory)
        do {
            try fileManager.createDirectory(at: cardsDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: file.fileURL, to: destination)
            return true
        } catch {
            // The slot keeps showing its placeholder rather than silently claiming success. A
            // future re-request or relaunch can retry.
            return false
        }
    }

    /// Each currently-cached collection's id and *directory* modification date, for feeding
    /// into `WatchCacheLayout.idsToEvict`.
    private func cachedModificationDates() -> [String: Date] {
        let root = WatchCacheLayout.collectionsDirectory(in: supportDirectory)
        let ids = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        var dates: [String: Date] = [:]
        for id in ids {
            let url = WatchCacheLayout.collectionDirectory(id: id, in: supportDirectory)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            dates[id] = modified ?? .distantPast
        }
        return dates
    }

    /// Evicts the least-recently-modified temporary (unpinned) cached collection directories
    /// down to `WatchCacheLayout.temporaryCacheLimit`. Pinned collections are never touched.
    /// Call after anything that could grow the temporary cache (a card or manifest arriving)
    /// or shrink the pinned set (an unpin).
    private func evictTemporaryFilesIfNeeded() {
        let evictable = WatchCacheLayout.idsToEvict(
            cachedModificationDates: cachedModificationDates(),
            pinned: pinStore.pinnedKeys
        )
        guard !evictable.isEmpty else { return }
        for id in evictable {
            try? fileManager.removeItem(at: WatchCacheLayout.collectionDirectory(id: id, in: supportDirectory))
            manifests[id] = nil
            receivedBlobs[id] = nil
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

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard
            let op = userInfo[WatchRelay.opKey] as? String,
            op == WatchRelay.opManifest,
            let id = userInfo[WatchRelay.idKey] as? String,
            let manifestData = userInfo[WatchRelay.manifestKey] as? Data,
            let manifest = WatchCacheLayout.decodeManifest(manifestData)
        else { return }
        Task { @MainActor in
            self.manifests[id] = manifest
            self.persistManifest(manifest, id: id)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard
            let metadata = file.metadata,
            let op = metadata[WatchRelay.opKey] as? String,
            op == WatchRelay.opCard,
            let id = metadata[WatchRelay.idKey] as? String,
            let cardName = metadata[WatchRelay.cardNameKey] as? String,
            let tier = metadata[WatchRelay.cardTierKey] as? String,
            let side = metadata[WatchRelay.cardSideKey] as? String
        else { return }
        let succeeded = cacheReceivedCardFile(file, id: id, cardName: cardName, tier: tier, side: side)
        Task { @MainActor in
            guard succeeded else { return }
            self.receivedBlobs[id, default: []].insert(WatchFaceKey(id: id, cardName: cardName, tier: tier, side: side))
            if !self.isPinned(id) {
                self.evictTemporaryFilesIfNeeded()
            }
        }
    }
}
