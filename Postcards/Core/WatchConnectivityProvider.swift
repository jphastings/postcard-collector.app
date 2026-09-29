#if os(iOS)
import CoreGraphics
import Foundation
import Observation
import os
import WatchConnectivity

private let logger = Logger(subsystem: "org.dotpostcard.collector", category: "WatchConnectivityProvider")

/// How long to wait for the watch to acknowledge one message before treating it as lost.
private let messageTimeout: TimeInterval = 20

/// The iPhone side of the watch relay (see `WatchRelay` for the wire contract). Publishes a
/// lightweight catalog of `CloudLibrary`'s collections as the `WCSession` application
/// context, keeps it in sync as the library changes, and answers the watch's requests by
/// streaming whatever of a collection it's missing: a manifest of every card's identity and
/// layout, the first missing cards as messages, the collection's details, the rest of the
/// cards' screen-tier faces through the file queue in display order, and — for a pinned
/// collection — zoom-tier faces trailing behind. It also answers a card the watch needs right
/// now (scrolled ahead to, or zoomed into) with just that card's faces, as messages. All pixel
/// work (splitting, un-rotating, downsampling, encoding) happens here on the phone; the watch
/// only ever decodes a ready-to-display image.
///
/// Compiled into the iOS target only — `WatchConnectivity` doesn't exist on macOS, and this
/// file is swept into `PostcardsTests` (a macOS bundle) along with the rest of `Postcards/Core`,
/// so the entire body must live behind `#if os(iOS)`.
@MainActor
final class WatchConnectivityProvider: NSObject, WCSessionDelegate {
    private let cloudLibrary: CloudLibrary
    private var lastPublishedCatalogData: Data?
    /// Set when the watch says it has never received a catalog (`opHello`): the next publish
    /// goes out even if it's unchanged, since the watch evidently doesn't have the last one.
    private var catalogPushRequested = false
    /// Collection ids currently being streamed, so a pin followed quickly by a request (or a
    /// retried watch request) doesn't race two overlapping streams for the same collection.
    private var inFlightStreamIDs: Set<String> = []
    /// The latest request for a collection that arrived while its previous stream was still
    /// running, run as soon as that one finishes — so, say, pinning a collection mid-browse
    /// still gets it its zoom tier.
    private var queuedRequests: [String: WatchDownloadRequest] = [:]
    /// Requests for ids not yet in `cloudLibrary.items` — e.g. a background launch delivering
    /// a queued request before `NSMetadataQuery` has gathered. Retried once the catalog
    /// changes (see `armCatalogObservation`).
    private var pendingRequests: [String: WatchDownloadRequest] = [:]
    /// Cards (by collection, card, and tier) whose faces are being sent in answer to an
    /// `opFocus`, so the watch asking again before they've landed doesn't send them twice.
    private var inFlightFocusKeys: Set<WatchFaceKey> = []

    init(cloudLibrary: CloudLibrary) {
        self.cloudLibrary = cloudLibrary
        super.init()
    }

    /// Activates the session, arms catalog observation, and starts the library. Call once at
    /// app launch — including a background launch, which is how a watch request reaches an app
    /// that isn't running; such a launch never shows `LibraryView`, whose task would otherwise
    /// start the library, and without it there's no catalog to publish or collection to
    /// stream. A no-op on hardware/OS combinations without Watch Connectivity support.
    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        armCatalogObservation()
        Task { await cloudLibrary.start() }
    }

    // MARK: - Catalog publishing

    /// Re-arms itself before publishing, so this keeps reacting to every subsequent change to
    /// the library — `withObservationTracking`'s `onChange` fires only once per call.
    private func armCatalogObservation() {
        withObservationTracking {
            _ = cloudLibrary.items
            _ = cloudLibrary.hasGatheredItems
            _ = cloudLibrary.containerState
        } onChange: { [weak self] in
            Task { @MainActor in self?.armCatalogObservation() }
        }
        publishCatalog()
        retryPendingRequests()
    }

    /// Whether `cloudLibrary.items` says anything yet: until the iCloud query's first gather,
    /// an empty list only means "not looked yet", and publishing it would tell the watch there
    /// are no collections. With no iCloud at all, empty is the real answer.
    private var isLibraryReady: Bool {
        cloudLibrary.hasGatheredItems || cloudLibrary.containerState == .unavailable
    }

    /// Re-attempts any request that arrived before its collection was in `cloudLibrary.items`
    /// (see `streamCollection`). Only touches ids whose item has since appeared — still-missing
    /// ids are left queued untouched, so this doesn't re-kick `cloudLibrary.start()` on every
    /// catalog change while genuinely waiting.
    private func retryPendingRequests() {
        for (id, request) in pendingRequests where collectionItem(id: id) != nil {
            pendingRequests[id] = nil
            streamCollection(id: id, request: request)
        }
    }

    /// Builds and pushes the catalog. Collection files already known to be `.current` are
    /// read for their real title/count; anything else gets a minimal entry rather than
    /// triggering a download just to advertise it. The (blocking, SQLite) reads happen off
    /// the main actor — `CloudItem` is `Sendable`, so the snapshot can safely cross.
    private func publishCatalog() {
        guard isLibraryReady else { return }
        let collections = cloudLibrary.items.filter { $0.isCollection }
        let forced = catalogPushRequested
        catalogPushRequested = false
        Task.detached(priority: .utility) { [weak self] in
            let catalog = collections.map(Self.catalogEntry(for:))
            guard let data = try? JSONEncoder().encode(catalog) else { return }
            await self?.pushCatalog(data, forced: forced)
        }
    }

    private nonisolated static func catalogEntry(for item: CloudItem) -> WatchCollectionInfo {
        guard item.downloadState == .current, let reader = try? CollectionReader(path: item.path) else {
            return WatchCatalogBuilder.entry(for: item, reader: nil)
        }
        return WatchCatalogBuilder.entry(for: item, reader: reader)
    }

    /// Latest-wins push, deduped against the last context we successfully set so an
    /// unchanged catalog (e.g. a query update for content we don't surface) doesn't churn
    /// `WCSession` — unless `forced`, when a nonce makes it go out regardless. Only recorded
    /// as "last published" once the push actually succeeds — a failed push (logged, not
    /// swallowed) must not poison the dedupe so a later retry of the same catalog is skipped.
    private func pushCatalog(_ data: Data, forced: Bool) {
        guard forced || data != lastPublishedCatalogData else { return }
        guard WCSession.default.activationState == .activated else { return }
        var context: [String: Any] = [WatchRelay.catalogKey: data]
        if forced {
            context[WatchRelay.catalogNonceKey] = UUID().uuidString
        }
        do {
            try WCSession.default.updateApplicationContext(context)
            lastPublishedCatalogData = data
        } catch {
            logger.error("Failed to push watch catalog (\(data.count) bytes): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Watch requests

    private func handleIncomingOp(_ payload: [String: Any]) {
        guard let op = payload[WatchRelay.opKey] as? String else { return }

        switch op {
        case WatchRelay.opHello:
            catalogPushRequested = true
            publishCatalog()
        case WatchRelay.opPin, WatchRelay.opRequest:
            guard let id = payload[WatchRelay.idKey] as? String else { return }
            let request = (payload[WatchRelay.downloadRequestKey] as? Data)
                .flatMap { try? JSONDecoder().decode(WatchDownloadRequest.self, from: $0) }
                ?? .everything
            streamCollection(id: id, request: request)
        case WatchRelay.opFocus:
            guard
                let id = payload[WatchRelay.idKey] as? String,
                let cardName = payload[WatchRelay.cardNameKey] as? String,
                let tier = payload[WatchRelay.cardTierKey] as? String
            else { return }
            sendFocusedCard(id: id, cardName: cardName, tier: tier, preferredSide: payload[WatchRelay.cardSideKey] as? String)
        default:
            // opUnpin: there's nothing in flight worth cancelling — anything still arriving
            // for an unpinned collection just becomes evictable on the watch.
            break
        }
    }

    private func collectionItem(id: String) -> CloudItem? {
        cloudLibrary.items.first { $0.isCollection && $0.displayName == id }
    }

    /// Starts streaming whatever of `id` the watch is missing, per `request`. If a stream for
    /// the same id is already running, the request waits for it to finish (see
    /// `queuedRequests`). If `id` isn't in `cloudLibrary.items` yet — a background launch or a
    /// request that beat `NSMetadataQuery`'s initial gather — it's queued rather than dropped,
    /// and `cloudLibrary.start()` is kicked (idempotent). `armCatalogObservation`'s change
    /// reaction retries queued ids once the catalog updates.
    ///
    /// `inFlightStreamIDs` only guards the few seconds this method's own encode/enqueue work
    /// takes — the queue it fills can take minutes to drain over Bluetooth. A request arriving
    /// after that is let through: it says what the watch already has, and `stream` also skips
    /// any face still sitting in `WCSession`'s outstanding queue, so it only ever adds what's
    /// genuinely missing.
    private func streamCollection(id: String, request: WatchDownloadRequest) {
        guard !inFlightStreamIDs.contains(id) else {
            queuedRequests[id] = request
            return
        }
        guard let item = collectionItem(id: id) else {
            pendingRequests[id] = request
            logger.info("queued stream for \(id, privacy: .public): library not ready")
            Task { await cloudLibrary.start() }
            return
        }

        inFlightStreamIDs.insert(id)
        Task.detached(priority: .userInitiated) { [weak self] in
            await Self.stream(item: item, id: id, request: request)
            await self?.markStreamFinished(id: id)
        }
    }

    private func markStreamFinished(id: String) {
        inFlightStreamIDs.remove(id)
        if let next = queuedRequests.removeValue(forKey: id) {
            streamCollection(id: id, request: next)
        }
    }

    /// Sends one card's faces at `tier` as messages, the showing side first, in answer to an
    /// `opFocus`. Unknown ids are ignored: focus is only ever asked for a collection the watch
    /// has open, which a stream has already found.
    private func sendFocusedCard(id: String, cardName: String, tier: String, preferredSide: String?) {
        let key = WatchFaceKey(id: id, cardName: cardName, tier: tier, side: "")
        guard !inFlightFocusKeys.contains(key), let item = collectionItem(id: id) else { return }

        inFlightFocusKeys.insert(key)
        Task.detached(priority: .userInitiated) { [weak self] in
            await Self.sendFocused(item: item, id: id, cardName: cardName, tier: tier, preferredSide: preferredSide)
            await self?.markFocusFinished(key)
        }
    }

    private func markFocusFinished(_ key: WatchFaceKey) {
        inFlightFocusKeys.remove(key)
    }

    // MARK: - Streaming

    /// The manifest + per-card streaming work, off the main actor: blocking SQLite reads,
    /// `ImageSplitter`'s pixel-level rotation, and ImageIO encoding all belong on a background
    /// thread, and `WCSession`'s transfer methods are documented as safe to call from any
    /// thread. A failure partway through (unreadable file, unsupported schema, ...) is logged
    /// and simply stops the stream — `markStreamFinished` still runs afterwards, so a later
    /// request can retry.
    ///
    /// Each card is split once, at full resolution, for both tiers: its screen faces are sent
    /// straight away, while its zoom faces (if wanted) are written out and only queued once
    /// every card's screen faces are — see `sendCard`.
    private nonisolated static func stream(item: CloudItem, id: String, request: WatchDownloadRequest) async {
        do {
            try await CloudLibrary.primeForGoCore(path: item.path)
            let reader = try CollectionReader(path: item.path)
            let summaries = try reader.cardSummaries()

            await sendManifest(summaries, id: id)

            let isWatchReachable = WCSession.default.isReachable
            let plan = WatchStreamPlan(
                cardNames: summaries.map(\.name),
                request: request,
                immediateLimit: isWatchReachable ? WatchRelay.immediateCardCount : 0
            )
            let zoomCards = Set(plan.queuedZoomCards)
            let alreadyQueued = outstandingCardFaceKeys()
            var zoomTransfers: [PendingTransfer] = []

            let immediateCards = Set(plan.immediateScreenCards)
            for (index, summary) in summaries.enumerated() where immediateCards.contains(summary.name) {
                await sendCard(
                    summary, index: index, count: summaries.count, id: id, reader: reader,
                    screen: .immediately, includeZoom: zoomCards.contains(summary.name),
                    alreadyQueued: alreadyQueued, zoomTransfers: &zoomTransfers
                )
            }

            if plan.sendsDetails {
                await sendDetails(summaries, id: id, reader: reader)
            }

            let queuedCards = Set(plan.queuedScreenCards)
            for (index, summary) in summaries.enumerated() where !immediateCards.contains(summary.name) {
                let screen: ScreenDelivery? = queuedCards.contains(summary.name) ? .queued : nil
                let includeZoom = zoomCards.contains(summary.name)
                guard screen != nil || includeZoom else { continue }
                await sendCard(
                    summary, index: index, count: summaries.count, id: id, reader: reader,
                    screen: screen, includeZoom: includeZoom,
                    alreadyQueued: alreadyQueued, zoomTransfers: &zoomTransfers
                )
            }

            for transfer in zoomTransfers {
                _ = WCSession.default.transferFile(transfer.url, metadata: transfer.metadata)
            }
            logger.info("streamed \(id, privacy: .public): \(plan.immediateScreenCards.count) cards as messages, \(plan.queuedScreenCards.count) queued, \(zoomTransfers.count) zoom faces queued")
        } catch {
            logger.error("Failed to stream watch collection \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// The answer to an `opFocus`: one card's faces at one tier, as messages (each falling
    /// back to the file queue if its messages don't get through), the side that's showing
    /// first.
    private nonisolated static func sendFocused(item: CloudItem, id: String, cardName: String, tier: String, preferredSide: String?) async {
        do {
            try await CloudLibrary.primeForGoCore(path: item.path)
            let reader = try CollectionReader(path: item.path)
            let summaries = try reader.cardSummaries()
            guard let index = summaries.firstIndex(where: { $0.name == cardName }) else { return }
            let summary = summaries[index]

            var faces = try splitFaces(of: summary, reader: reader)
            if let preferred = faces.firstIndex(where: { $0.side == preferredSide }) {
                faces.insert(faces.remove(at: preferred), at: 0)
            }
            for face in faces {
                guard let blob = encodedFace(face.image, tier: tier, side: face.side, cardName: cardName, id: id) else { continue }
                let metadata = faceMetadata(summary, index: index, count: summaries.count, id: id, tier: tier, side: face.side)
                await sendPreferringMessages(blob, metadata: metadata)
            }
        } catch {
            logger.error("Failed to send focused card \"\(cardName, privacy: .public)\" in \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Snapshots the faces currently sitting in `WCSession`'s outstanding-transfer list, so
    /// `stream` can skip re-encoding and re-enqueuing a face that's still draining from an
    /// earlier stream of the same collection instead of piling a duplicate onto the queue.
    /// `outstandingFileTransfers` is documented safe to read from any thread.
    ///
    /// Taken once, at the start of a stream: the queue only shrinks while we're sending (as
    /// transfers finish draining), so a snapshot from the start can at worst under-skip —
    /// resending something that finished mid-stream — never over-skip.
    private nonisolated static func outstandingCardFaceKeys() -> Set<WatchFaceKey> {
        Set(WCSession.default.outstandingFileTransfers.compactMap { faceKey(fromMetadata: $0.file.metadata ?? [:]) })
    }

    /// The face a queued transfer carries, or `nil` if it isn't a card-face transfer (wrong or
    /// missing op) or is missing a field. Defensive rather than force-unwrapped, since this
    /// reads metadata `WCSession` handed back to us, not metadata we just built ourselves.
    private nonisolated static func faceKey(fromMetadata metadata: [String: Any]) -> WatchFaceKey? {
        guard
            metadata[WatchRelay.opKey] as? String == WatchRelay.opCard,
            let id = metadata[WatchRelay.idKey] as? String,
            let cardName = metadata[WatchRelay.cardNameKey] as? String,
            let tier = metadata[WatchRelay.cardTierKey] as? String,
            let side = metadata[WatchRelay.cardSideKey] as? String
        else { return nil }
        return WatchFaceKey(id: id, cardName: cardName, tier: tier, side: side)
    }

    /// Sends the manifest as a message when the watch is looking (the collection opens the
    /// moment it lands), otherwise — or if that fails — on the reliable user-info queue.
    private nonisolated static func sendManifest(_ summaries: [CardSummary], id: String) async {
        let manifest = summaries.map {
            WatchCardMeta(name: $0.name, flip: $0.flip, frontPxW: $0.frontPxW, frontPxH: $0.frontPxH)
        }
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        let payload: [String: Any] = [
            WatchRelay.opKey: WatchRelay.opManifest,
            WatchRelay.idKey: id,
            WatchRelay.manifestKey: data,
        ]
        if data.count <= WatchRelay.messageChunkSize, await sendAcknowledgedMessage(payload) {
            return
        }
        _ = WCSession.default.transferUserInfo(payload)
    }

    /// Sends the collection's details — every card's `WatchCardDetails`, for the watch's info
    /// page — preferring messages. A card whose full metadata can't be read still gets the
    /// details its summary carries.
    private nonisolated static func sendDetails(_ summaries: [CardSummary], id: String, reader: CollectionReader) async {
        let details = summaries.map { WatchCardDetails(summary: $0, metadata: try? reader.metadata(name: $0.name)) }
        guard let data = try? JSONEncoder().encode(details) else { return }
        await sendPreferringMessages(data, metadata: [WatchRelay.opKey: WatchRelay.opDetails, WatchRelay.idKey: id])
    }

    /// How `sendCard` delivers a card's screen faces.
    private enum ScreenDelivery {
        /// As messages, ahead of the queue (falling back to it if they don't get through).
        case immediately
        /// Through the file queue — unless the face is already sitting in it.
        case queued
    }

    /// A face's blob already written to a temp file, with its `transferFile` metadata, ready
    /// to hand to `WCSession` at the right point in the send order.
    private struct PendingTransfer {
        let url: URL
        let metadata: [String: Any]
    }

    /// Splits one card's stored (combined front+back) image ONCE at full resolution, then
    /// sends its screen faces as `screen` says (or not at all, if `nil`), and — if
    /// `includeZoom` — writes out its zoom faces and appends them to `zoomTransfers`, for the
    /// caller to queue after every card's screen faces. Best-effort: a card that can't be read
    /// or split, or one face that fails to encode, is logged and skipped rather than aborting
    /// the rest of the collection's stream. A face still draining from an earlier stream of
    /// this collection (`alreadyQueued`) isn't queued again.
    private nonisolated static func sendCard(
        _ summary: CardSummary,
        index: Int,
        count: Int,
        id: String,
        reader: CollectionReader,
        screen: ScreenDelivery?,
        includeZoom: Bool,
        alreadyQueued: Set<WatchFaceKey>,
        zoomTransfers: inout [PendingTransfer]
    ) async {
        let faces: [(image: CGImage, side: String)]
        do {
            faces = try splitFaces(of: summary, reader: reader)
        } catch {
            logger.error("Failed to send card \"\(summary.name, privacy: .public)\" in \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }

        for (image, side) in faces {
            let screenKey = WatchFaceKey(id: id, cardName: summary.name, tier: WatchRelay.tierScreen, side: side)
            if let screen, screen == .immediately || !alreadyQueued.contains(screenKey),
               let blob = encodedFace(image, tier: WatchRelay.tierScreen, side: side, cardName: summary.name, id: id) {
                let metadata = faceMetadata(summary, index: index, count: count, id: id, tier: WatchRelay.tierScreen, side: side)
                switch screen {
                case .immediately:
                    await sendPreferringMessages(blob, metadata: metadata)
                case .queued:
                    queue(blob, metadata: metadata)
                }
            }

            let zoomKey = WatchFaceKey(id: id, cardName: summary.name, tier: WatchRelay.tierZoom, side: side)
            if includeZoom, !alreadyQueued.contains(zoomKey),
               let blob = encodedFace(image, tier: WatchRelay.tierZoom, side: side, cardName: summary.name, id: id) {
                let metadata = faceMetadata(summary, index: index, count: count, id: id, tier: WatchRelay.tierZoom, side: side)
                do {
                    zoomTransfers.append(PendingTransfer(url: try writeTempBlob(blob), metadata: metadata))
                } catch {
                    logger.error("Couldn't write zoom face of card \"\(summary.name, privacy: .public)\" in \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// A card's faces — the front, and the back if it has one — split out of its stored
    /// combined image at full resolution, the back already turned upright.
    private nonisolated static func splitFaces(of summary: CardSummary, reader: CollectionReader) throws -> [(image: CGImage, side: String)] {
        let split = try ImageSplitter.split(data: reader.imageData(name: summary.name), flip: summary.flip)
        var faces: [(image: CGImage, side: String)] = [(split.front, WatchRelay.sideFront)]
        if let back = split.back {
            faces.append((back, WatchRelay.sideBack))
        }
        return faces
    }

    /// Downsamples and encodes one face for `tier`. `nil` (logged) if the encode fails; the
    /// caller carries on to the next face or tier rather than aborting the whole card.
    private nonisolated static func encodedFace(_ image: CGImage, tier: String, side: String, cardName: String, id: String) -> Data? {
        let isZoom = tier == WatchRelay.tierZoom
        let blob = WatchCardImage.encodedFace(
            image,
            maxPixelSize: isZoom ? WatchRelay.zoomTierMaxPixelSize : WatchRelay.screenTierMaxPixelSize,
            quality: isZoom ? WatchRelay.zoomTierQuality : WatchRelay.screenTierQuality
        )
        if blob == nil {
            logger.error("Couldn't encode \(side, privacy: .public)/\(tier, privacy: .public) face of card \"\(cardName, privacy: .public)\" in \(id, privacy: .public)")
        }
        return blob
    }

    private nonisolated static func faceMetadata(_ summary: CardSummary, index: Int, count: Int, id: String, tier: String, side: String) -> [String: Any] {
        [
            WatchRelay.opKey: WatchRelay.opCard,
            WatchRelay.idKey: id,
            WatchRelay.cardNameKey: summary.name,
            WatchRelay.cardTierKey: tier,
            WatchRelay.cardSideKey: side,
            WatchRelay.cardIndexKey: index,
            WatchRelay.cardCountKey: count,
        ]
    }

    // MARK: - Delivery

    /// Sends a blob as acknowledged messages if the watch is reachable, falling back to the
    /// file queue if it isn't, or if any of the messages doesn't get through — so the blob
    /// always arrives, just sooner when the watch is looking.
    private nonisolated static func sendPreferringMessages(_ blob: Data, metadata: [String: Any]) async {
        let deliveredAsMessages = await sendAsMessages(blob, metadata: metadata)
        guard !deliveredAsMessages else { return }
        queue(blob, metadata: metadata)
    }

    /// Sends a blob as one or more messages (see `WatchRelay`'s "Blobs as messages"), each
    /// acknowledged by the watch before the next goes — which paces the chunks to what the
    /// link can carry. `false` as soon as one isn't acknowledged, leaving the watch to discard
    /// whatever part it got.
    private nonisolated static func sendAsMessages(_ blob: Data, metadata: [String: Any]) async -> Bool {
        let chunks = WatchMessageChunks.chunks(of: blob, maxChunkSize: WatchRelay.messageChunkSize)
        let blobID = UUID().uuidString
        for (index, chunk) in chunks.enumerated() {
            var message = metadata
            message[WatchRelay.blobKey] = chunk
            message[WatchRelay.blobIDKey] = blobID
            message[WatchRelay.chunkIndexKey] = index
            message[WatchRelay.chunkCountKey] = chunks.count
            guard await sendAcknowledgedMessage(message) else { return false }
        }
        return true
    }

    /// `sendMessage` with a reply handler, as one async call: `true` once the watch has
    /// replied, `false` if it isn't reachable, the message fails, or no answer comes within
    /// `messageTimeout`.
    private nonisolated static func sendAcknowledgedMessage(_ message: [String: Any]) async -> Bool {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return false }
        return await withCheckedContinuation { continuation in
            let outcome = MessageOutcome(continuation)
            session.sendMessage(message, replyHandler: { _ in
                outcome.resolve(true)
            }, errorHandler: { error in
                logger.info("watch message not delivered: \(String(describing: error), privacy: .public)")
                outcome.resolve(false)
            })
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + messageTimeout) {
                outcome.resolve(false)
            }
        }
    }

    /// Resumes a message's continuation exactly once, whichever of its reply handler, error
    /// handler, or timeout gets there first.
    private final class MessageOutcome: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resolve(_ delivered: Bool) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: delivered)
        }
    }

    /// Queues a blob as a file transfer. Its temp file is removed once `WCSession` reports
    /// the transfer finished (see `session(_:didFinish:error:)`).
    private nonisolated static func queue(_ blob: Data, metadata: [String: Any]) {
        do {
            _ = WCSession.default.transferFile(try writeTempBlob(blob), metadata: metadata)
        } catch {
            logger.error("Couldn't write a watch transfer: \(String(describing: error), privacy: .public)")
        }
    }

    private nonisolated static func writeTempBlob(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publishCatalog() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate so the session keeps relaying after a watch pairing change, per Apple's
        // documented requirement for this callback.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.handleIncomingOp(userInfo) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.handleIncomingOp(message) }
    }

    /// Removes the temp file backing a card transfer once `WCSession` has finished copying
    /// it into its own queue (successfully or not) — deleting any earlier risks racing the
    /// system's read of it. No `@MainActor` state involved, so this stays nonisolated.
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if let error {
            logger.error("Watch card transfer failed: \(String(describing: error), privacy: .public)")
        }
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}
#endif
