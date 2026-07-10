#if os(iOS)
import Foundation
import Observation
import WatchConnectivity

/// The iPhone side of the watch relay (see `WatchRelay` for the wire contract). Publishes a
/// lightweight catalog of `CloudLibrary`'s collections as the `WCSession` application
/// context, keeps it in sync as the library changes, and answers the watch's pin/request ops
/// by transferring a collection's whole `.postcards` file.
///
/// Compiled into the iOS target only — `WatchConnectivity` doesn't exist on macOS, and this
/// file is swept into `PostcardsTests` (a macOS bundle) along with the rest of `Postcards/Core`,
/// so the entire body must live behind `#if os(iOS)`.
@MainActor
final class WatchConnectivityProvider: NSObject, WCSessionDelegate {
    private let cloudLibrary: CloudLibrary
    private var lastPublishedCatalogData: Data?

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
    /// read for their real title/count/thumbnail; anything else gets a minimal entry rather
    /// than triggering a download just to advertise it. The (blocking, SQLite) reads happen
    /// off the main actor — `CloudItem` is `Sendable`, so the snapshot can safely cross.
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

    /// Latest-wins push, deduped against the last context we set so an unchanged catalog
    /// (e.g. a query update for content we don't surface) doesn't churn `WCSession`.
    private func pushCatalogIfNeeded(_ data: Data) {
        guard data != lastPublishedCatalogData else { return }
        guard WCSession.default.activationState == .activated else { return }
        lastPublishedCatalogData = data
        try? WCSession.default.updateApplicationContext([WatchRelay.catalogKey: data])
    }

    // MARK: - Watch requests

    private func handleIncomingOp(_ payload: [String: Any]) {
        guard
            let op = payload[WatchRelay.opKey] as? String,
            let id = payload[WatchRelay.idKey] as? String
        else { return }

        switch op {
        case WatchRelay.opPin, WatchRelay.opRequest:
            Task { await self.transferFile(forCollectionID: id) }
        case WatchRelay.opUnpin:
            // Phase 1 has no way to cancel an already-started transferFile; the watch simply
            // discards a file that arrives for a collection it has since unpinned.
            break
        default:
            break
        }
    }

    private func transferFile(forCollectionID id: String) async {
        guard let item = cloudLibrary.items.first(where: { $0.isCollection && $0.displayName == id }) else { return }
        do {
            try await CloudLibrary.primeForGoCore(path: item.path)
        } catch {
            return
        }
        _ = WCSession.default.transferFile(URL(fileURLWithPath: item.path), metadata: [WatchRelay.fileIdKey: id])
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
}
#endif
