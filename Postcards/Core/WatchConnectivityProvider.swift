#if os(iOS)
import CoreGraphics
import Foundation
import Observation
import os
import WatchConnectivity

private let logger = Logger(subsystem: "org.dotpostcard.collector", category: "WatchConnectivityProvider")

/// The iPhone side of the watch relay (see `WatchRelay` for the wire contract). Publishes a
/// lightweight catalog of `CloudLibrary`'s collections as the `WCSession` application
/// context, keeps it in sync as the library changes, and answers the watch's pin/request ops
/// by streaming a collection progressively: a manifest of every card's identity/layout, then
/// each card's faces (front, and back if present) as their own file transfers — screen-tier
/// sized first in display order, so the watch can show the first postcard within a second or
/// two, then zoom-tier sized trailing behind for double-tap sharpness. All pixel work
/// (splitting, un-rotating, downsampling, encoding) happens here on the phone; the watch only
/// ever decodes a ready-to-display image.
///
/// Compiled into the iOS target only — `WatchConnectivity` doesn't exist on macOS, and this
/// file is swept into `PostcardsTests` (a macOS bundle) along with the rest of `Postcards/Core`,
/// so the entire body must live behind `#if os(iOS)`.
@MainActor
final class WatchConnectivityProvider: NSObject, WCSessionDelegate {
    private let cloudLibrary: CloudLibrary
    private var lastPublishedCatalogData: Data?
    /// Collection ids currently being streamed, so a pin followed quickly by a request (or a
    /// retried watch request) doesn't race two overlapping streams for the same collection.
    private var inFlightStreamIDs: Set<String> = []

    init(cloudLibrary: CloudLibrary) {
        self.cloudLibrary = cloudLibrary
        super.init()
    }

    /// Activates the session and arms catalog observation. Safe to call once at app launch;
    /// a no-op on hardware/OS combinations without Watch Connectivity support.
    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        armCatalogObservation()
    }

    // MARK: - Catalog publishing

    /// Re-arms itself before publishing, so this keeps reacting to every subsequent change to
    /// `cloudLibrary.items` — `withObservationTracking`'s `onChange` fires only once per call.
    private func armCatalogObservation() {
        withObservationTracking {
            _ = cloudLibrary.items
        } onChange: { [weak self] in
            Task { @MainActor in self?.armCatalogObservation() }
        }
        publishCatalog()
    }

    /// Builds and pushes the catalog. Collection files already known to be `.current` are
    /// read for their real title/count; anything else gets a minimal entry rather than
    /// triggering a download just to advertise it. The (blocking, SQLite) reads happen off
    /// the main actor — `CloudItem` is `Sendable`, so the snapshot can safely cross.
    private func publishCatalog() {
        let collections = cloudLibrary.items.filter { $0.isCollection }
        Task.detached(priority: .utility) { [weak self] in
            let catalog = collections.map(Self.catalogEntry(for:))
            guard let data = try? JSONEncoder().encode(catalog) else { return }
            await self?.pushCatalogIfNeeded(data)
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
    /// `WCSession`. Only recorded as "last published" once the push actually succeeds — a
    /// failed push (logged, not swallowed) must not poison the dedupe so a later retry of the
    /// same catalog is skipped.
    private func pushCatalogIfNeeded(_ data: Data) {
        guard data != lastPublishedCatalogData else { return }
        guard WCSession.default.activationState == .activated else { return }
        do {
            try WCSession.default.updateApplicationContext([WatchRelay.catalogKey: data])
            lastPublishedCatalogData = data
        } catch {
            logger.error("Failed to push watch catalog (\(data.count) bytes): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Watch requests

    private func handleIncomingOp(_ payload: [String: Any]) {
        guard
            let op = payload[WatchRelay.opKey] as? String,
            let id = payload[WatchRelay.idKey] as? String
        else { return }

        switch op {
        case WatchRelay.opPin, WatchRelay.opRequest:
            streamCollectionIfNeeded(id: id)
        case WatchRelay.opUnpin:
            // There's nothing in flight to cancel: the watch simply discards a manifest/card
            // that lands for a collection it has since unpinned.
            break
        default:
            break
        }
    }

    /// Starts streaming `id`'s manifest and cards to the watch, unless a stream for the same
    /// id is already running.
    private func streamCollectionIfNeeded(id: String) {
        guard !inFlightStreamIDs.contains(id) else { return }
        guard let item = cloudLibrary.items.first(where: { $0.isCollection && $0.displayName == id }) else { return }

        inFlightStreamIDs.insert(id)
        Task.detached(priority: .utility) { [weak self] in
            await Self.stream(item: item, id: id)
            await self?.markStreamFinished(id: id)
        }
    }

    private func markStreamFinished(id: String) {
        inFlightStreamIDs.remove(id)
    }

    /// The manifest + per-card streaming work, off the main actor: blocking SQLite reads,
    /// `ImageSplitter`'s pixel-level rotation, and ImageIO encoding all belong on a background
    /// thread, and `WCSession`'s transfer methods are documented as safe to call from any
    /// thread. A failure partway through (unreadable file, unsupported schema, ...) is logged
    /// and simply stops the stream — `markStreamFinished` still runs afterwards, so a later
    /// opRequest can retry.
    ///
    /// Each card is split once, at full resolution, into its faces; screen-tier transfers are
    /// enqueued immediately (so `transferFile`'s FIFO queue carries them first, in scroll
    /// order) while zoom-tier transfers are buffered and only enqueued once every card's
    /// screen tier is queued — see `sendCardFaces`.
    private nonisolated static func stream(item: CloudItem, id: String) async {
        do {
            try await CloudLibrary.primeForGoCore(path: item.path)
            let reader = try CollectionReader(path: item.path)
            let summaries = try reader.cardSummaries()

            sendManifest(summaries, id: id)

            var zoomTransfers: [PendingFaceTransfer] = []
            for (index, summary) in summaries.enumerated() {
                sendCardFaces(summary, index: index, count: summaries.count, id: id, reader: reader, zoomTransfers: &zoomTransfers)
            }
            for transfer in zoomTransfers {
                _ = WCSession.default.transferFile(transfer.url, metadata: transfer.metadata)
            }
        } catch {
            logger.error("Failed to stream watch collection \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private nonisolated static func sendManifest(_ summaries: [CardSummary], id: String) {
        let manifest = summaries.map {
            WatchCardMeta(name: $0.name, flip: $0.flip, frontPxW: $0.frontPxW, frontPxH: $0.frontPxH)
        }
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        _ = WCSession.default.transferUserInfo([
            WatchRelay.opKey: WatchRelay.opManifest,
            WatchRelay.idKey: id,
            WatchRelay.manifestKey: data,
        ])
    }

    /// A face's blob already written to a temp file, with its `transferFile` metadata, ready
    /// to hand to `WCSession` — or to hold onto until the right point in the send order.
    private struct PendingFaceTransfer {
        let url: URL
        let metadata: [String: Any]
    }

    /// Splits one card's stored (combined front+back) image ONCE at full resolution, then
    /// produces up to four face blobs (front/back × screen/zoom, back only if the card has
    /// one). Screen-tier faces are sent immediately; zoom-tier faces are appended to
    /// `zoomTransfers` for the caller to send after every card's screen tier has been queued.
    /// Best-effort: a single unreadable/undecodable card, or one face that fails to encode, is
    /// logged and skipped rather than aborting the rest of the collection's stream.
    private nonisolated static func sendCardFaces(
        _ summary: CardSummary,
        index: Int,
        count: Int,
        id: String,
        reader: CollectionReader,
        zoomTransfers: inout [PendingFaceTransfer]
    ) {
        do {
            let imageData = try reader.imageData(name: summary.name)
            let split = try ImageSplitter.split(data: imageData, flip: summary.flip)

            var faces: [(image: CGImage, side: String)] = [(split.front, WatchRelay.sideFront)]
            if let back = split.back {
                faces.append((back, WatchRelay.sideBack))
            }

            for (image, side) in faces {
                if let transfer = try faceTransfer(
                    image, tier: WatchRelay.tierScreen, maxPixelSize: WatchRelay.screenTierMaxPixelSize,
                    side: side, summary: summary, index: index, count: count, id: id
                ) {
                    _ = WCSession.default.transferFile(transfer.url, metadata: transfer.metadata)
                }
                if let transfer = try faceTransfer(
                    image, tier: WatchRelay.tierZoom, maxPixelSize: WatchRelay.zoomTierMaxPixelSize,
                    side: side, summary: summary, index: index, count: count, id: id
                ) {
                    zoomTransfers.append(transfer)
                }
            }
        } catch {
            logger.error("Failed to send card \"\(summary.name, privacy: .public)\" in \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Downsamples+encodes one face at one tier and writes it to a temp file. `nil` (logged)
    /// if the encode fails; the caller carries on to the next face/tier rather than aborting
    /// the whole card.
    private nonisolated static func faceTransfer(
        _ image: CGImage,
        tier: String,
        maxPixelSize: Int,
        side: String,
        summary: CardSummary,
        index: Int,
        count: Int,
        id: String
    ) throws -> PendingFaceTransfer? {
        guard let blob = WatchCardImage.encodedFace(image, maxPixelSize: maxPixelSize) else {
            logger.error("Couldn't encode \(side, privacy: .public)/\(tier, privacy: .public) face of card \"\(summary.name, privacy: .public)\" in \(id, privacy: .public)")
            return nil
        }
        let url = try writeTempBlob(blob)
        return PendingFaceTransfer(url: url, metadata: [
            WatchRelay.opKey: WatchRelay.opCard,
            WatchRelay.idKey: id,
            WatchRelay.cardNameKey: summary.name,
            WatchRelay.cardTierKey: tier,
            WatchRelay.cardSideKey: side,
            WatchRelay.cardIndexKey: index,
            WatchRelay.cardCountKey: count,
        ])
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
