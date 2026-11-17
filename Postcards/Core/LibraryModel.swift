import Foundation
import Observation

/// The local collections shown in `LibraryView`'s "Local" section: whatever the user has opened
/// (file importer, ⌘O, drag-and-drop, or Open With). Nothing is bundled — a fresh install starts
/// empty (see `LibraryView`'s empty-library state). Bare `.postcard.*` files are never kept:
/// opening one validates it and hands it back to the caller to show in its own window.
///
/// **macOS opens files in place.** The app references the original on disk (the Mac isn't
/// sandboxed, so no security scope is needed) and remembers each one by a bookmark stored in
/// `UserDefaults`. A bookmark still resolves after the file is *moved*, so the reference follows
/// it; a file that can no longer be found is dropped from the list on the next launch. "Remove"
/// forgets the reference without touching the file.
///
/// **iOS/iPadOS still copy** each opened file into the app container
/// (`Application Support/ImportedSources`) and open the copy — the sandbox makes open-in-place
/// bookmarks fiddlier there, and iOS is slated to become iCloud-only anyway (see TODO). Restored
/// on relaunch by rescanning the container.
@MainActor
@Observable
final class LibraryModel {
    private(set) var sources: [LibrarySource] = []

    /// The most recent import failure, for the UI to surface as an alert. Never leave a dead
    /// grid: anything that stops a picked file from opening ends up here.
    var importError: String?

    /// The most recently selected sidebar collection's path, tracked purely so the
    /// "Create a Postcard" destination picker can preselect it.
    var lastSelectedCollectionPath: String?

    /// Bumped whenever a card is added to a collection from outside its own grid view (e.g.
    /// the create-postcard flow's separate window/cover) — `CollectionGridView` keys its
    /// content-loading `.task(id:)` on this alongside the source, so the new card appears
    /// without the user having to reselect the collection.
    var contentGeneration = 0

    /// Component-bundle files (`{name}-front/back/only.<img>`, `{name}-meta.yaml`) opened from
    /// outside "Create a Postcard", waiting for that window to take them in and prefill from.
    var pendingCreateImport: [URL] = []

    private static let collectionSuffix = ".postcards"
    private static let cardSuffixes = [".postcard.webp", ".postcard.jpg", ".postcard.jpeg", ".postcard.png", ".postcard"]
    private static let knownSuffixes = [collectionSuffix] + cardSuffixes

    private struct ImportError: LocalizedError {
        let errorDescription: String?
    }

    #if os(macOS)
    private let defaults: UserDefaults
    private static let bookmarksKey = "localSourceBookmarks"

    /// Where "New collection…" writes a brand-new local collection when iCloud isn't available.
    /// These are app-authored (not copies of opened files), tracked by the same bookmark mechanism.
    nonisolated static var localCollectionsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Collections", directoryHint: .isDirectory)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreBookmarkedSources()
    }
    #else
    private let importDirectory: URL

    nonisolated static var defaultImportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "ImportedSources", directoryHint: .isDirectory)
    }

    init(importDirectory: URL = LibraryModel.defaultImportDirectory) {
        self.importDirectory = importDirectory
        restorePreviousImports()
    }
    #endif

    /// Opens each picked file. Shared by every entry point: file importer, macOS ⌘O open panel,
    /// drag-and-drop, and onOpenURL. Collections become sources (macOS references them in place;
    /// iOS copies them in). Bare card files are only validated, and returned — as URLs the app
    /// can read for as long as it shows them — for the caller to open in their own window.
    @discardableResult
    func importSources(from urls: [URL]) async -> [URL] {
        var failures: [String] = []
        var cards: [URL] = []
        for url in urls {
            do {
                try Self.requireKnownSuffix(url)
                #if os(macOS)
                if isCollectionFile(url) {
                    try await openInPlace(url)
                } else {
                    _ = try await GoCore.shared.summary(ofCardFileAt: url.path)
                    cards.append(url)
                }
                #else
                if isCollectionFile(url) {
                    let copied = try await Self.copy(url, into: importDirectory)
                    try await addValidatedSource(at: copied)
                } else {
                    let copied = try await Self.copy(url, into: Self.openedCardsDirectory)
                    _ = try await GoCore.shared.summary(ofCardFileAt: copied.path)
                    cards.append(copied)
                }
                #endif
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            importError = failures.joined(separator: "\n")
        }
        return cards
    }

    private static func requireKnownSuffix(_ url: URL) throws {
        let filename = url.lastPathComponent.lowercased()
        guard knownSuffixes.contains(where: { filename.hasSuffix($0) }) else {
            throw ImportError(errorDescription: "Not a postcard file (expected \(knownSuffixes.joined(separator: ", "))).")
        }
    }

    /// Adds a just-created collection (the "New collection…" flow) as a source — it was created
    /// in place a moment ago, so there's nothing to copy or validate. On macOS it's remembered by
    /// bookmark like an opened file.
    func registerCollection(at url: URL) {
        upsert(.collection(path: url.path, displayName: Self.displayName(for: url)))
        #if os(macOS)
        rememberBookmark(for: url)
        #endif
    }

    /// Forgets the source at `path`: drops it from the list. On macOS this removes its bookmark but
    /// leaves the original file untouched (it was only ever referenced in place — "Remove" is
    /// "stop listing it", not "delete it"; that's `deleteCollection`). A no-op if `path` isn't a
    /// known source (e.g. it was synced in from iCloud).
    func remove(path: String) {
        sources.removeAll { $0.path == path }
        #if os(macOS)
        saveBookmarks(loadBookmarks().filter { resolvedPath(of: $0) != path })
        #endif
    }

    private func upsert(_ source: LibrarySource) {
        if let existing = sources.firstIndex(where: { $0.path == source.path }) {
            sources[existing] = source
        } else {
            sources.append(source)
        }
    }

    private static func displayName(for url: URL) -> String {
        let filename = url.lastPathComponent
        for suffix in knownSuffixes where filename.lowercased().hasSuffix(suffix) {
            return String(filename.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func isCollectionFile(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().hasSuffix(Self.collectionSuffix)
    }

    private func addSource(for url: URL) {
        upsert(.collection(path: url.path, displayName: Self.displayName(for: url)))
    }

    #if os(macOS)

    // MARK: - Open in place (macOS)

    private func openInPlace(_ url: URL) async throws {
        // Validate it opens via the Go core at its real path, so a corrupt/non-postcard file is
        // reported now instead of leaving a dead grid.
        _ = try await GoCore.shared.cardSummaries(inCollectionAt: url.path)
        rememberBookmark(for: url)
        addSource(for: url)
    }

    // MARK: - Bookmark persistence (macOS)

    private func loadBookmarks() -> [Data] {
        (defaults.array(forKey: Self.bookmarksKey) as? [Data]) ?? []
    }

    private func saveBookmarks(_ data: [Data]) {
        defaults.set(data, forKey: Self.bookmarksKey)
    }

    private func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func resolvedPath(of bookmark: Data) -> String? {
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))?.path
    }

    private func rememberBookmark(for url: URL) {
        guard let bookmark = makeBookmark(for: url) else { return }
        var all = loadBookmarks()
        // Re-opening the same file replaces its bookmark rather than duplicating it.
        all.removeAll { resolvedPath(of: $0) == url.path }
        all.append(bookmark)
        saveBookmarks(all)
    }

    /// On launch, resolve every remembered bookmark: keep those that still resolve — updating the
    /// reference to the file's current location and refreshing a stale bookmark — and drop those
    /// whose file can no longer be found, along with any bare card files earlier versions kept.
    /// Rewrites the stored set so the drops/refreshes persist.
    private func restoreBookmarkedSources() {
        var kept: [Data] = []
        var seen = Set<String>()
        for bookmark in loadBookmarks() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                continue // file gone — drop it
            }
            guard isCollectionFile(url), seen.insert(url.path).inserted else { continue }
            kept.append(stale ? (makeBookmark(for: url) ?? bookmark) : bookmark)
            addSource(for: url)
        }
        saveBookmarks(kept)
    }

    #else

    // MARK: - Copy into container (iOS)

    /// Where an opened bare card is copied so it stays readable while it's shown. Temporary:
    /// cards are never kept in-app.
    nonisolated static var openedCardsDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "OpenedPostcards", directoryHint: .isDirectory)
    }

    private static func copy(_ url: URL, into directory: URL) async throws -> URL {
        let destination = directory.appending(path: url.lastPathComponent)

        await GoCore.shared.invalidateSource(at: destination.path)

        try await Task.detached(priority: .userInitiated) {
            let hasScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasScope { url.stopAccessingSecurityScopedResource() }
            }

            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                do {
                    try fm.copyItem(at: readableURL, to: destination)
                } catch {
                    copyError = error
                }
            }
            if let error = coordinationError ?? copyError {
                throw error
            }
        }.value

        return destination
    }

    private func addValidatedSource(at url: URL) async throws {
        do {
            _ = try await GoCore.shared.cardSummaries(inCollectionAt: url.path)
            addSource(for: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func restorePreviousImports() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: importDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if isCollectionFile(url) {
                addSource(for: url)
            }
        }
    }

    #endif
}

extension LibraryModel {
    /// Every collection a card can be added to — imported plus fully-downloaded iCloud ones,
    /// deduplicated by path (see `WritableCollection.known(sources:downloaded:)`). A
    /// just-created iCloud collection can briefly be in both `sources` and `cloudLibrary.items`.
    func writableCollections(with cloudLibrary: CloudLibrary) -> [WritableCollection] {
        let downloaded = cloudLibrary.items
            .filter { $0.isCollection && $0.downloadState == .current }
            .map { WritableCollection(path: $0.path, displayName: $0.displayName) }
        return WritableCollection.known(sources: sources, downloaded: downloaded)
    }
}
