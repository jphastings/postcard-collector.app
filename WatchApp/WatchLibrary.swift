import Foundation
import Observation
import WatchConnectivity

/// The watch's whole data layer: a `WCSessionDelegate` that receives the iPhone's catalog
/// (pushed as the application context) and streams each pinned/requested collection
/// progressively — a manifest naming every card slot, then each card FACE's (front/back, at a
/// screen or zoom tier) ready-to-display image, plus the collection's details for the info
/// page — caching all of it to disk so the app has something to show with no phone present.
/// watchOS can't open iCloud Drive documents, so unlike the abandoned `CloudLibrary` design
/// this never touches iCloud itself — see `WatchRelay` for the wire contract with the
/// iPhone's (iOS-only) relay, including which parts travel as immediate messages.
///
/// WCSession's delegate callbacks fire on a private background queue, but everything
/// observable here is `@MainActor` state (via the class-wide `@MainActor`/`@Observable`).
/// Every delegate method below is therefore `nonisolated`: it writes whatever arrived to disk
/// synchronously — a transferred file's temporary URL is reclaimed as soon as the callback
/// returns, and a background launch can be suspended right after — then hops back with
/// `Task { @MainActor in ... }` before touching that state. This app has a history of
/// heap-corruption crashes from off-main mutation, so there's no shortcut here.
@MainActor
@Observable
final class WatchLibrary: NSObject {
    private(set) var catalog: [WatchCollectionInfo] = []
    /// Whether a catalog has ever arrived from the iPhone — now, or on an earlier launch (it's
    /// persisted). Until one has, an empty `catalog` means "never heard from the iPhone app"
    /// rather than "no collections", and the list invites the person to open it.
    private(set) var hasReceivedCatalog = false
    private(set) var isPhoneReachable = false
    /// `id` -> its manifest, once the phone's streamed it. A collection is "present" (its
    /// slots can be laid out) the moment this lands, even if not every card's blob has
    /// arrived yet.
    private(set) var manifests: [String: [WatchCardMeta]] = [:]
    /// `id` -> the faces (one entry per card/tier/side) whose blob is cached on disk. Faces
    /// arrive in scroll order (screen tier for every card, then any zoom tier trailing behind)
    /// but this is a `Set`, not an ordered list, because a card's slot position comes from the
    /// manifest — this only answers "has this particular face landed yet".
    private(set) var receivedBlobs: [String: Set<WatchFaceKey>] = [:]
    /// `id` -> card name -> that card's info-page details, once the phone's sent them.
    private(set) var cardDetails: [String: [String: WatchCardDetails]] = [:]
    /// Collections asked for whose manifest hasn't arrived yet — what the list shows a
    /// spinner for.
    private(set) var awaitingManifestIDs: Set<String> = []
    /// Observable mirror of `pinStore.pinnedKeys` — `pinStore` itself is a plain
    /// UserDefaults-backed object, not `@Observable`, so `isPinned(_:)` reading it directly
    /// would register no Observation dependency and toggling a pin would never re-render
    /// `WatchCollectionListView`. Kept in sync with `pinStore` by every mutating call site.
    private(set) var pinnedIDs: Set<String>

    private let pinStore: PinStore
    /// Injected for the main-actor disk methods (test seam). The `nonisolated` receive path
    /// uses `FileManager.default` directly instead — `FileManager` isn't `Sendable`, so it
    /// can't be shared into a `nonisolated` context.
    private let fileManager: FileManager
    /// `URL` is `Sendable`, so this stays readable from the `nonisolated` delegate methods
    /// below; only the mutable, `@Observable` properties above need a main-actor hop.
    private nonisolated let supportDirectory: URL
    /// An `actor` is inherently `Sendable`, so — like `supportDirectory` above — this is
    /// readable from any isolation domain (the `nonisolated` delegate methods, or a SwiftUI
    /// view) without a main-actor hop; only its own internal state needs synchronizing, which
    /// the actor already does.
    nonisolated let decodedFaceCache = WatchDecodedFaceCache()
    /// Reassembles blobs the phone sends as several messages. Only ever touched from
    /// WCSession's delegate callbacks, off the main actor — so it synchronizes itself.
    private nonisolated let chunkInbox = WatchChunkInbox()

    /// When each collection was last asked for, so opening it again or a reachability flap
    /// doesn't re-ask for a stream that's still arriving.
    @ObservationIgnored private var lastRequestDates: [String: Date] = [:]
    /// When anything for each collection last arrived — how a stalled stream is spotted.
    @ObservationIgnored private var lastArrivalDates: [String: Date] = [:]
    /// When each card/tier was last asked for as a focus request.
    @ObservationIgnored private var lastFocusDates: [WatchFaceKey: Date] = [:]
    @ObservationIgnored private var lastHelloDate: Date?

    /// A repeat request inside this window is dropped unless forced (a stall retry).
    private static let requestDebounce: TimeInterval = 20
    /// A repeat focus request for the same card and tier inside this window is dropped.
    private static let focusDebounce: TimeInterval = 10
    /// How often an unanswered hello may be repeated.
    private static let helloInterval: TimeInterval = 30
    /// How long the list shows a collection as waiting on a request that hasn't produced a
    /// manifest.
    private static let awaitingManifestTimeout: Duration = .seconds(60)

    init(
        pinStore: PinStore = PinStore(),
        fileManager: FileManager = .default,
        supportDirectory: URL? = nil
    ) {
        self.pinStore = pinStore
        self.fileManager = fileManager
        self.supportDirectory = supportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.pinnedIDs = pinStore.pinnedKeys
        super.init()
        restoreCatalog()
        restoreCollectionsFromDisk()
        // Self-heal if the temporary cache limit was ever exceeded across a relaunch (e.g. a
        // crash mid-eviction, or a lowered cap in a future build).
        evictTemporaryFilesIfNeeded()
    }

    /// Activates the session. Call once, at app launch — see `WatchPostcardsApp`.
    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Keeps a background launch alive until WatchConnectivity has handed over everything it
    /// was holding for this app — the app is suspended as soon as the `.watchConnectivity`
    /// background task that calls this returns, and returning early would strand the rest
    /// until the next launch. Bounded, in case the session never activates.
    func waitForPendingContent() async {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        let deadline = Date().addingTimeInterval(25)
        while !Task.isCancelled, Date() < deadline,
              session.activationState != .activated || session.hasContentPending {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func isPinned(_ id: String) -> Bool {
        pinnedIDs.contains(id)
    }

    func manifest(for id: String) -> [WatchCardMeta]? {
        manifests[id]
    }

    func details(for id: String, cardName: String) -> WatchCardDetails? {
        cardDetails[id]?[cardName]
    }

    func cardBlobURL(_ id: String, cardName: String, tier: String, side: String) -> URL? {
        let url = WatchCacheLayout.cardBlobURL(id: id, cardName: cardName, tier: tier, side: side, in: supportDirectory)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether one face's blob has landed.
    func hasFace(id: String, cardName: String, tier: String, side: String) -> Bool {
        receivedBlobs[id]?.contains(WatchFaceKey(id: id, cardName: cardName, tier: tier, side: side)) ?? false
    }

    private func hasFaces(id: String, cardName: String, tier: String, hasBack: Bool) -> Bool {
        hasFace(id: id, cardName: cardName, tier: tier, side: WatchRelay.sideFront)
            && (!hasBack || hasFace(id: id, cardName: cardName, tier: tier, side: WatchRelay.sideBack))
    }

    /// Whether the SCREEN tier (front, and back if `hasBack`) has landed for this card — what a
    /// card view waits for before it can render at all.
    func hasScreenFaces(id: String, cardName: String, hasBack: Bool) -> Bool {
        hasFaces(id: id, cardName: cardName, tier: WatchRelay.tierScreen, hasBack: hasBack)
    }

    /// Whether the ZOOM tier has landed for both of this card's sides.
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

    func isAwaitingManifest(_ id: String) -> Bool {
        awaitingManifestIDs.contains(id)
    }

    /// Whether everything the watch keeps for `id` has landed: its manifest, its details,
    /// every card's screen faces — and, for a pinned collection (kept for offline use), every
    /// card's zoom faces too. Unpinned collections fetch zoom faces card by card, as they're
    /// zoomed into.
    func isComplete(_ id: String) -> Bool {
        guard let manifest = manifests[id], cardDetails[id] != nil else { return false }
        let wantsZoom = isPinned(id)
        return manifest.allSatisfy { meta in
            let hasBack = meta.flip != .none
            return hasScreenFaces(id: id, cardName: meta.name, hasBack: hasBack)
                && (!wantsZoom || hasZoomFaces(id: id, cardName: meta.name, hasBack: hasBack))
        }
    }

    /// Pinning keeps a collection downloaded (and exempt from eviction) permanently, zoom tier
    /// and all; unpinning lets it fall back to being *temporary*, subject to eviction, rather
    /// than deleting it outright — so unpinning something you're currently viewing doesn't yank
    /// it out from under you.
    func setPinned(_ pinned: Bool, id: String) {
        if pinned {
            pinStore.setPinned(true, for: id)
            pinnedIDs.insert(id)
            // Forced: a request for this collection moments ago (browsing it) didn't ask for
            // the zoom tier that pinning now wants.
            requestDownloadIfNeeded(id: id, force: true)
        } else {
            unpin(id: id)
            evictTemporaryFilesIfNeeded()
        }
    }

    /// Marks `id` unpinned in both `pinStore` and the observable `pinnedIDs` mirror, and tells
    /// the phone. Shared by `setPinned(false, ...)` and `removeDownload`, which both need this
    /// same notify step.
    private func unpin(id: String) {
        pinStore.setPinned(false, for: id)
        pinnedIDs.remove(id)
        send([WatchRelay.opKey: WatchRelay.opUnpin, WatchRelay.idKey: id], reliably: true)
    }

    /// Deletes a downloaded collection outright, unlike unpinning alone (which only makes the
    /// cache eligible for background eviction): unpins it first if pinned, removes its on-disk
    /// cache directory, clears its in-memory state, and invalidates any of its faces still
    /// held in `decodedFaceCache`.
    func removeDownload(id: String) {
        if isPinned(id) {
            unpin(id: id)
        }
        try? fileManager.removeItem(at: WatchCacheLayout.collectionDirectory(id: id, in: supportDirectory))
        forgetCollection(id)
        lastRequestDates[id] = nil
        Task { await decodedFaceCache.invalidate(collectionID: id) }
    }

    private func forgetCollection(_ id: String) {
        manifests[id] = nil
        receivedBlobs[id] = nil
        cardDetails[id] = nil
        awaitingManifestIDs.remove(id)
    }

    // MARK: - Asking the phone

    /// Asks the phone to stream whatever of `id` the watch doesn't hold yet — pinning and
    /// live-viewing a collection both funnel through here; whether the result is later
    /// evicted depends only on `isPinned`, not on which caller asked. The request lists what's
    /// already here (see `WatchDownloadRequest`), so resuming an interrupted download, or
    /// fetching what an older build's cache lacks (its details), only sends the difference.
    ///
    /// A no-op once `isComplete`, and — unless `force`d — within `requestDebounce` of the last
    /// request, which is still arriving. Needs the phone in range, except for a pinned
    /// collection, whose request can wait in the reliable queue until it is.
    func requestDownloadIfNeeded(id: String, force: Bool = false) {
        guard isPhoneReachable || isPinned(id), !isComplete(id) else { return }
        let now = Date()
        if !force, let last = lastRequestDates[id], now.timeIntervalSince(last) < Self.requestDebounce {
            return
        }
        guard let requestData = try? JSONEncoder().encode(downloadRequest(for: id)) else { return }
        lastRequestDates[id] = now
        if manifests[id] == nil, isPhoneReachable {
            awaitingManifestIDs.insert(id)
            Task { [weak self] in
                try? await Task.sleep(for: Self.awaitingManifestTimeout)
                guard let self, self.lastRequestDates[id] == now else { return }
                self.awaitingManifestIDs.remove(id)
            }
        }
        send([
            WatchRelay.opKey: WatchRelay.opRequest,
            WatchRelay.idKey: id,
            WatchRelay.downloadRequestKey: requestData,
        ], reliably: true)
    }

    /// Re-requests `id` if it's incomplete and nothing for it has arrived — or been asked
    /// for — in `interval`: the phone app may have been suspended mid-stream. Resent requests
    /// list what's here, so this never re-sends what already arrived.
    func requestDownloadIfStalled(id: String, interval: TimeInterval) {
        guard !isComplete(id) else { return }
        let lastActivity = max(lastRequestDates[id] ?? .distantPast, lastArrivalDates[id] ?? .distantPast)
        guard Date().timeIntervalSince(lastActivity) >= interval else { return }
        requestDownloadIfNeeded(id: id, force: true)
    }

    /// Asks the phone for one card's faces at `tier` right now, as messages — for the card on
    /// screen that the queue hasn't reached (screen tier), or that's just been zoomed into
    /// (zoom tier). Messages only reach a phone in range, so this is a no-op otherwise, and a
    /// repeat inside `focusDebounce` is dropped while the first answer is on its way.
    func requestFocus(id: String, cardName: String, tier: String, preferredSide: String?) {
        guard isPhoneReachable else { return }
        let key = WatchFaceKey(id: id, cardName: cardName, tier: tier, side: "")
        let now = Date()
        if let last = lastFocusDates[key], now.timeIntervalSince(last) < Self.focusDebounce {
            return
        }
        lastFocusDates[key] = now
        var payload: [String: Any] = [
            WatchRelay.opKey: WatchRelay.opFocus,
            WatchRelay.idKey: id,
            WatchRelay.cardNameKey: cardName,
            WatchRelay.cardTierKey: tier,
        ]
        if let preferredSide {
            payload[WatchRelay.cardSideKey] = preferredSide
        }
        send(payload, reliably: false)
    }

    /// What to tell the phone `id` already has.
    private func downloadRequest(for id: String) -> WatchDownloadRequest {
        let manifest = manifests[id] ?? []
        var request = WatchDownloadRequest()
        request.haveScreen = Set(manifest.filter { hasScreenFaces(id: id, cardName: $0.name, hasBack: $0.flip != .none) }.map(\.name))
        request.haveZoom = Set(manifest.filter { hasZoomFaces(id: id, cardName: $0.name, hasBack: $0.flip != .none) }.map(\.name))
        request.haveDetails = cardDetails[id] != nil
        request.wantsZoom = isPinned(id)
        return request
    }

    /// Until a catalog has ever arrived, nudges the iPhone app: a message wakes it in the
    /// background even if it's never been opened, so it can publish its catalog without the
    /// person having to open it. Rate-limited.
    private func sayHelloIfNeeded() {
        guard !hasReceivedCatalog, isPhoneReachable else { return }
        let now = Date()
        if let lastHelloDate, now.timeIntervalSince(lastHelloDate) < Self.helloInterval {
            return
        }
        lastHelloDate = now
        send([WatchRelay.opKey: WatchRelay.opHello], reliably: false)
    }

    /// Picks interrupted pinned downloads back up whenever the phone comes (back) into range.
    private func resumePinnedDownloads() {
        for info in catalog where isPinned(info.id) && !isComplete(info.id) {
            requestDownloadIfNeeded(id: info.id)
        }
    }

    /// Sends a watch → phone op: as a message when the phone is in range — it arrives at once,
    /// and wakes the iPhone app if it isn't running — and otherwise, or if the message fails,
    /// on the reliable user-info queue when `reliably`.
    private func send(_ payload: [String: Any], reliably: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard session.isReachable else {
            if reliably {
                _ = session.transferUserInfo(payload)
            }
            return
        }
        session.sendMessage(payload, replyHandler: nil) { _ in
            guard reliably else { return }
            _ = WCSession.default.transferUserInfo(payload)
        }
    }

    // MARK: - Arrivals

    private func adoptCatalog(_ catalog: [WatchCollectionInfo]) {
        self.catalog = catalog
        hasReceivedCatalog = true
        resumePinnedDownloads()
    }

    /// Adopts (and persists) the catalog the session was already holding at activation — only
    /// if none has ever arrived here, since anything newer comes through the delegate.
    private func adoptDeliveredCatalog(_ catalog: [WatchCollectionInfo]) {
        guard !hasReceivedCatalog else { return }
        if let data = WatchCacheLayout.encodeCatalog(catalog) {
            _ = Self.store(.data(data), at: WatchCacheLayout.catalogFileURL(in: supportDirectory))
        }
        adoptCatalog(catalog)
    }

    private func adoptManifest(_ manifest: [WatchCardMeta], id: String) {
        let isNewCollection = manifests[id] == nil && receivedBlobs[id] == nil
        if manifests[id] != manifest {
            manifests[id] = manifest
        }
        awaitingManifestIDs.remove(id)
        lastArrivalDates[id] = Date()
        if isNewCollection {
            evictTemporaryFilesIfNeeded()
        }
    }

    private func recordFace(_ key: WatchFaceKey) {
        let isNewCollection = manifests[key.id] == nil && receivedBlobs[key.id] == nil
        receivedBlobs[key.id, default: []].insert(key)
        lastArrivalDates[key.id] = Date()
        // A card arriving only adds to a collection's directory; eviction only needs
        // re-checking when a collection's directory first appears.
        if isNewCollection {
            evictTemporaryFilesIfNeeded()
        }
    }

    private func adoptDetails(_ details: [WatchCardDetails], id: String) {
        cardDetails[id] = Dictionary(details.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        lastArrivalDates[id] = Date()
    }

    private func phoneReachabilityChanged(_ reachable: Bool) {
        isPhoneReachable = reachable
        guard reachable else {
            // Nothing asked for can arrive now, so stop showing it as on its way.
            awaitingManifestIDs.removeAll()
            return
        }
        sayHelloIfNeeded()
        resumePinnedDownloads()
    }

    // MARK: - Disk cache

    private func restoreCatalog() {
        let url = WatchCacheLayout.catalogFileURL(in: supportDirectory)
        guard
            let data = fileManager.contents(atPath: url.path),
            let restored = WatchCacheLayout.decodeCatalog(data)
        else { return }
        catalog = restored
        hasReceivedCatalog = true
    }

    /// Rebuilds the per-collection state on launch by scanning `Collections/` — the source of
    /// truth is always the disk, not anything persisted alongside it, so a crash or forced
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
            if
                let data = fileManager.contents(atPath: WatchCacheLayout.detailsURL(id: id, in: supportDirectory).path),
                let details = WatchCacheLayout.decodeDetails(data)
            {
                cardDetails[id] = Dictionary(details.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
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

    /// Writes an arrival to its place in the cache — synchronously, on whatever thread
    /// WCSession calls the delegate on (see the type's doc comment). A transferred file is
    /// moved into place; a blob that came as messages, or a manifest or catalog, is written.
    /// Returns whether it succeeded, so the caller only records what's really on disk; a
    /// failure leaves the slot showing its placeholder until a later request retries it.
    private nonisolated static func store(_ contents: WatchArrival, at destination: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch contents {
            case .file(let source):
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: source, to: destination)
            case .data(let data):
                try data.write(to: destination, options: .atomic)
            }
            return true
        } catch {
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
    /// Call after anything that could grow the temporary cache (a new collection's first
    /// arrival) or shrink the pinned set (an unpin).
    private func evictTemporaryFilesIfNeeded() {
        let evictable = WatchCacheLayout.idsToEvict(
            cachedModificationDates: cachedModificationDates(),
            pinned: pinStore.pinnedKeys
        )
        for id in evictable {
            try? fileManager.removeItem(at: WatchCacheLayout.collectionDirectory(id: id, in: supportDirectory))
            forgetCollection(id)
        }
    }
}

/// Something that arrived from the phone, to be filed in the cache: a transferred file (at
/// the temporary URL WCSession hands over), or bytes that came in messages.
private enum WatchArrival {
    case file(URL)
    case data(Data)
}

/// `WatchChunkAssembler` behind a lock, for WatchConnectivity's delegate queue.
private final class WatchChunkInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var assembler = WatchChunkAssembler()

    func add(chunk: Data, index: Int, count: Int, blobID: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return assembler.add(chunk: chunk, index: index, count: count, blobID: blobID)
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
        // A catalog the system delivered while this app wasn't running, in case the delegate
        // callback for it never comes (it's only for *new* contexts).
        let deliveredCatalog = (session.receivedApplicationContext[WatchRelay.catalogKey] as? Data)
            .flatMap(WatchCacheLayout.decodeCatalog)
        Task { @MainActor in
            if let deliveredCatalog {
                self.adoptDeliveredCatalog(deliveredCatalog)
            }
            self.phoneReachabilityChanged(reachable)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.phoneReachabilityChanged(reachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard
            let data = applicationContext[WatchRelay.catalogKey] as? Data,
            let catalog = WatchCacheLayout.decodeCatalog(data)
        else { return }
        _ = Self.store(.data(data), at: WatchCacheLayout.catalogFileURL(in: supportDirectory))
        Task { @MainActor in
            self.adoptCatalog(catalog)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        receiveManifest(userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveMessage(message)
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        receiveMessage(message)
        replyHandler([:])
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let metadata = file.metadata else { return }
        receiveBlob(metadata: metadata, contents: .file(file.fileURL))
    }

    private nonisolated func receiveMessage(_ message: [String: Any]) {
        let op = message[WatchRelay.opKey] as? String
        if op == WatchRelay.opManifest {
            receiveManifest(message)
        } else if op == WatchRelay.opCard || op == WatchRelay.opDetails {
            guard
                let chunk = message[WatchRelay.blobKey] as? Data,
                let blob = chunkInbox.add(
                    chunk: chunk,
                    index: message[WatchRelay.chunkIndexKey] as? Int ?? 0,
                    count: message[WatchRelay.chunkCountKey] as? Int ?? 1,
                    blobID: message[WatchRelay.blobIDKey] as? String ?? ""
                )
            else { return }
            receiveBlob(metadata: message, contents: .data(blob))
        }
    }

    private nonisolated func receiveManifest(_ payload: [String: Any]) {
        guard
            payload[WatchRelay.opKey] as? String == WatchRelay.opManifest,
            let id = payload[WatchRelay.idKey] as? String,
            let data = payload[WatchRelay.manifestKey] as? Data,
            let manifest = WatchCacheLayout.decodeManifest(data)
        else { return }
        _ = Self.store(.data(data), at: WatchCacheLayout.manifestURL(id: id, in: supportDirectory))
        Task { @MainActor in
            self.adoptManifest(manifest, id: id)
        }
    }

    /// Files one card face or details blob, then records it on the main actor.
    private nonisolated func receiveBlob(metadata: [String: Any], contents: WatchArrival) {
        guard
            let op = metadata[WatchRelay.opKey] as? String,
            let id = metadata[WatchRelay.idKey] as? String
        else { return }

        if op == WatchRelay.opCard {
            guard
                let cardName = metadata[WatchRelay.cardNameKey] as? String,
                let tier = metadata[WatchRelay.cardTierKey] as? String,
                let side = metadata[WatchRelay.cardSideKey] as? String
            else { return }
            let destination = WatchCacheLayout.cardBlobURL(id: id, cardName: cardName, tier: tier, side: side, in: supportDirectory)
            guard Self.store(contents, at: destination) else { return }
            let key = WatchFaceKey(id: id, cardName: cardName, tier: tier, side: side)
            Task { @MainActor in
                self.recordFace(key)
            }
        } else if op == WatchRelay.opDetails {
            let destination = WatchCacheLayout.detailsURL(id: id, in: supportDirectory)
            guard
                Self.store(contents, at: destination),
                let data = FileManager.default.contents(atPath: destination.path),
                let details = WatchCacheLayout.decodeDetails(data)
            else { return }
            Task { @MainActor in
                self.adoptDetails(details, id: id)
            }
        }
    }
}
