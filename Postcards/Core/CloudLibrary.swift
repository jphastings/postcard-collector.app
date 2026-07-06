import Foundation
import Observation

/// One thing found in the app's iCloud ubiquity container: a `.postcards` collection or a
/// bare `.postcard.*` card file. Classified from `NSMetadataItem` attributes rather than
/// the on-disk filename, because iCloud renames undownloaded files to `.<name>.icloud` —
/// the metadata item's `NSMetadataItemFSNameKey` still reports the real name.
struct CloudItem: Identifiable, Hashable, Sendable {
    enum DownloadState: Hashable, Sendable {
        case current
        case downloading(percent: Double)
        case remote
    }

    var path: String
    var displayName: String
    var isCollection: Bool
    var downloadState: DownloadState

    var id: String { path }

    /// The existing library source this maps onto. `LibraryView`/`CollectionGridView`
    /// don't need to know a source came from iCloud rather than the file importer.
    var librarySource: LibrarySource {
        isCollection ? .collection(path: path, displayName: displayName) : .cardFile(path: path, displayName: displayName)
    }
}

/// Pure classification logic for `NSMetadataItem` attributes, kept free of
/// `NSMetadataQuery`/`NSMetadataItem` itself so it can be unit tested without a real
/// ubiquity container.
enum CloudItemAttributes {
    enum Kind: Equatable {
        case collection
        case card
        case other
    }

    private static let cardSuffixPattern = #"\.postcard\.[a-z0-9]+$"#

    static func kind(forFilename filename: String) -> Kind {
        let lower = filename.lowercased()
        if lower.hasSuffix(".postcards") { return .collection }
        if lower.range(of: cardSuffixPattern, options: .regularExpression) != nil { return .card }
        return .other
    }

    static func displayName(forFilename filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".postcards") {
            return String(filename.dropLast(".postcards".count))
        }
        if let range = lower.range(of: cardSuffixPattern, options: .regularExpression) {
            let suffixLength = lower.distance(from: range.lowerBound, to: lower.endIndex)
            return String(filename.dropLast(suffixLength))
        }
        return (filename as NSString).deletingPathExtension
    }

    /// Maps the raw `NSMetadataUbiquitousItemDownloadingStatusKey` value (and, while a
    /// download is in flight, the percent-downloaded attribute) to a download state.
    static func downloadState(status: String?, percentDownloaded: Double?) -> CloudItem.DownloadState {
        if status == NSMetadataUbiquitousItemDownloadingStatusCurrent {
            return .current
        }
        if let percentDownloaded, percentDownloaded > 0, percentDownloaded < 100 {
            return .downloading(percent: percentDownloaded)
        }
        return .remote
    }

    /// Whether a metadata update represents new content on disk for a path we'd already
    /// seen, rather than the item's first sighting (which is never a "change" — there's
    /// nothing to invalidate yet).
    static func hasContentChanged(previousChangeDate: Date?, currentChangeDate: Date?) -> Bool {
        guard let previousChangeDate, let currentChangeDate else { return false }
        return currentChangeDate > previousChangeDate
    }
}

/// Watches the app's iCloud ubiquity container for `.postcards` collections and bare
/// `.postcard.*` card files, downloading them on demand and feeding cloud-backed
/// `LibrarySource`s to the rest of the app.
///
/// Container resolution happens off the main thread and degrades quietly: a `nil`
/// container (not signed into iCloud, or the entitlement isn't provisioned on this build)
/// leaves `containerState` at `.unavailable` forever, and every other part of the app
/// works exactly as it does without iCloud — this is never surfaced as a launch-time
/// error, only a quiet hint in `LibraryView`.
@MainActor
@Observable
final class CloudLibrary {
    enum ContainerState: Equatable {
        case resolving
        case unavailable
        case available
    }

    private(set) var containerState: ContainerState = .resolving
    private(set) var items: [CloudItem] = []
    /// The container's Documents folder (the visible "Postcards" folder in iCloud Drive),
    /// once resolved — where the "New collection…" flow creates files when iCloud is
    /// available, so they sync like any other dropped-in collection.
    private(set) var documentsURL: URL?

    private let containerIdentifier: String
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    /// The last known on-disk content-change date per path, so a later update for the
    /// same (already-current) path can be recognised as "this collection was replaced by
    /// sync" rather than a redundant re-affirmation of the same content.
    private var lastKnownContentChangeDates: [String: Date] = [:]

    init(containerIdentifier: String = "iCloud.org.dotpostcard.collector") {
        self.containerIdentifier = containerIdentifier
    }

    /// Resolves the ubiquity container and, if available, starts watching it. Safe to
    /// call once at app launch; does nothing destructive if the container never resolves.
    func start() async {
        let identifier = containerIdentifier
        let documentsURL = await Task.detached(priority: .utility) { () -> URL? in
            let fm = FileManager.default
            guard let container = fm.url(forUbiquityContainerIdentifier: identifier) else { return nil }
            let documents = container.appending(path: "Documents", directoryHint: .isDirectory)
            try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
            return documents
        }.value

        guard let documentsURL else {
            containerState = .unavailable
            return
        }

        self.documentsURL = documentsURL
        containerState = .available
        startQuery()
    }

    // MARK: - NSMetadataQuery

    private func startQuery() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = Self.metadataQueryPredicate()

        let center = NotificationCenter.default
        for name: Notification.Name in [.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleQueryUpdate() }
            })
        }

        self.query = query
        query.start()
    }

    private func handleQueryUpdate() {
        guard let query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }

        var updated: [CloudItem] = []
        for case let metadataItem as NSMetadataItem in query.results {
            guard let item = Self.makeCloudItem(from: metadataItem) else { continue }
            updated.append(item)

            downloadIfNeeded(item)
            reopenIfContentChanged(item, contentChangeDate: metadataItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)
        }
        items = updated.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func makeCloudItem(from item: NSMetadataItem) -> CloudItem? {
        guard let filename = item.value(forAttribute: NSMetadataItemFSNameKey) as? String else { return nil }
        let kind = CloudItemAttributes.kind(forFilename: filename)
        guard kind != .other else { return nil }
        guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { return nil }

        let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        let percent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double

        return CloudItem(
            path: url.path,
            displayName: CloudItemAttributes.displayName(forFilename: filename),
            isCollection: kind == .collection,
            downloadState: CloudItemAttributes.downloadState(status: status, percentDownloaded: percent)
        )
    }

    private func downloadIfNeeded(_ item: CloudItem) {
        guard item.downloadState != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: item.path))
    }

    /// Collections and bare files can be replaced wholesale by iCloud sync at any time —
    /// if a path we already knew about picks up newer content, drop any cached Go core
    /// handle so the next access reopens against the new file instead of reading through
    /// a stale SQLite handle on an inode that no longer matches what's on disk.
    private func reopenIfContentChanged(_ item: CloudItem, contentChangeDate: Date?) {
        guard item.downloadState == .current else { return }
        defer {
            if let contentChangeDate { lastKnownContentChangeDates[item.path] = contentChangeDate }
        }

        guard CloudItemAttributes.hasContentChanged(
            previousChangeDate: lastKnownContentChangeDates[item.path],
            currentChangeDate: contentChangeDate
        ) else { return }

        Task { await GoCore.shared.invalidateSource(at: item.path) }
    }

    // MARK: - Coordinated reads

    /// Hands a cloud-backed path to the Go core only after a short coordinated read: Go's
    /// SQLite/file access goes straight through C file APIs, which don't participate in
    /// `NSFileCoordinator` on their own, so without this a concurrent iCloud sync write
    /// could be read mid-update. Mirrors the coordinated copy `LibraryModel` already does
    /// for provider-backed import sources.
    nonisolated static func primeForGoCore(path: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try withCoordinatedRead(at: path) { _ in }
        }.value
    }

    private nonisolated static func withCoordinatedRead<T>(at path: String, _ body: (String) throws -> T) throws -> T {
        let url = URL(fileURLWithPath: path)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result { try body(readableURL.path) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    // MARK: - Coordinated writes

    /// The write-side counterpart to `primeForGoCore`: brackets a no-op accessor in a
    /// coordinated **write** so a concurrent iCloud sync yields for a beat before the real
    /// write — performed afterwards, sequentially, via the Go core (which, like reads,
    /// doesn't participate in `NSFileCoordinator` on its own) — touches the file. Call this
    /// before any `GoCore` write to a path that might be iCloud-hosted.
    nonisolated static func primeForGoCoreWrite(path: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try withCoordinatedWrite(at: path) { _ in }
        }.value
    }

    /// Deletes the file at `path`, coordinating the delete so it's safe for iCloud-hosted
    /// paths too (harmless, uncontended overhead for a purely local file).
    nonisolated static func deleteCoordinated(at path: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try withCoordinatedWrite(at: path, options: .forDeleting) { deletableURL in
                try FileManager.default.removeItem(at: deletableURL)
            }
        }.value
    }

    private nonisolated static func withCoordinatedWrite<T>(
        at path: String,
        options: NSFileCoordinator.WritingOptions = [],
        _ body: (URL) throws -> T
    ) throws -> T {
        let url = URL(fileURLWithPath: path)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { writableURL in
            result = Result { try body(writableURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    // MARK: - Predicate

    /// Matches `*.postcards` collections and bare `*.postcard.*` card files by their real
    /// filesystem name (`NSMetadataItemFSNameKey`), which — unlike the on-disk file at an
    /// undownloaded item's URL — is never obscured by iCloud's `.<name>.icloud` renaming.
    nonisolated static func metadataQueryPredicate() -> NSPredicate {
        NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*.postcards"),
            NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*.postcard.*"),
        ])
    }
}
