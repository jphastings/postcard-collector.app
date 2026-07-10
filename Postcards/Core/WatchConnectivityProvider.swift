#if os(iOS)
import Foundation
import Observation
import os
import WatchConnectivity

private let logger = Logger(subsystem: "org.dotpostcard.collector", category: "WatchConnectivityProvider")

/// The iPhone side of the watch relay (see `WatchRelay` for the wire contract). Publishes a
/// lightweight catalog of `CloudLibrary`'s collections as the `WCSession` application
/// context, keeps it in sync as the library changes, and answers the watch's pin/request ops
/// by streaming a collection progressively: a manifest of every card's identity/layout, then
/// each card's downsampled image as its own file transfer, in display order — so the watch
/// can show the first postcard within a second or two instead of waiting for a whole
/// `.postcards` file.
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

    /// The manifest + per-card streaming work, off the main actor: blocking SQLite reads and
    /// ImageIO downsampling both belong on a background thread, and `WCSession`'s transfer
    /// methods are documented as safe to call from any thread. A failure partway through
    /// (unreadable file, unsupported schema, ...) is logged and simply stops the stream —
    /// `markStreamFinished` still runs afterwards, so a later opRequest can retry.
    private nonisolated static func stream(item: CloudItem, id: String) async {
        do {
            try await CloudLibrary.primeForGoCore(path: item.path)
            let reader = try CollectionReader(path: item.path)
            let summaries = try reader.cardSummaries()

            sendManifest(summaries, id: id)
            for (index, summary) in summaries.enumerated() {
                sendCard(summary, index: index, count: summaries.count, id: id, reader: reader)
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

    /// Downsamples and streams one card's image. Best-effort: a single unreadable/undecodable
    /// card is logged and skipped rather than aborting the rest of the collection's stream.
    private nonisolated static func sendCard(_ summary: CardSummary, index: Int, count: Int, id: String, reader: CollectionReader) {
        do {
            let imageData = try reader.imageData(name: summary.name)
            guard let blob = WatchCardImage.downsampled(imageData) else {
                logger.error("Couldn't downsample card \"\(summary.name, privacy: .public)\" in \(id, privacy: .public)")
                return
            }
            let tempURL = try writeTempBlob(blob)
            _ = WCSession.default.transferFile(tempURL, metadata: [
                WatchRelay.opKey: WatchRelay.opCard,
                WatchRelay.idKey: id,
                WatchRelay.cardNameKey: summary.name,
                WatchRelay.cardIndexKey: index,
                WatchRelay.cardCountKey: count,
            ])
        } catch {
            logger.error("Failed to send card \"\(summary.name, privacy: .public)\" in \(id, privacy: .public): \(String(describing: error), privacy: .public)")
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
