import Foundation
import Observation

/// The local sources shown in `LibraryView`'s "Local" section: whatever the user has opened
/// (file importer, ⌘O, drag-and-drop, or Open With). Nothing is bundled — a fresh install starts
/// empty (see `LibraryView`'s empty-library state).
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

    private static let collectionSuffix = ".postcards"
    private static let cardSuffixes = [".postcard.webp", ".postcard.jpg", ".postcard.jpeg", ".postcard.png", ".postcard"]
    private static let knownSuffixes = [collectionSuffix] + cardSuffixes

    private struct ImportError: LocalizedError {
        let errorDescription: String?
    }

    #if os(macOS)
    private let defaults: UserDefaults
    /// Where `addBareCard` writes — defaults to `localBareCardsDirectory`, injectable so tests
    /// don't write into the real Application Support directory (mirrors iOS's `importDirectory`
    /// injection below).
    private let bareCardsDirectory: URL
    private static let bookmarksKey = "localSourceBookmarks"

    /// Where "New collection…" writes a brand-new local collection when iCloud isn't available.
    /// These are app-authored (not copies of opened files), tracked by the same bookmark mechanism.
    nonisolated static var localCollectionsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Collections", directoryHint: .isDirectory)
    }

    /// Sibling of `localCollectionsDirectory`: where `addBareCard` writes a freshly compiled
    /// card when the create-postcard flow's destination is "Individual postcards" rather than
    /// a collection. Also app-authored, also bookmarked (see `addBareCard`).
    nonisolated static var localBareCardsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Individual Postcards", directoryHint: .isDirectory)
    }

    init(defaults: UserDefaults = .standard, bareCardsDirectory: URL = LibraryModel.localBareCardsDirectory) {
        self.defaults = defaults
        self.bareCardsDirectory = bareCardsDirectory
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
    /// drag-and-drop, and onOpenURL. macOS references the file in place; iOS copies it in.
    func importSources(from urls: [URL]) async {
        var failures: [String] = []
        for url in urls {
            do {
                #if os(macOS)
                try await openInPlace(url)
                #else
                let copied = try await copyIntoContainer(url)
                try await addValidatedSource(at: copied)
                #endif
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            importError = failures.joined(separator: "\n")
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

    /// Writes a freshly compiled bare postcard file — the "Create a Postcard" flow's default
    /// destination when no collection is chosen (`CreatePostcardModel.destinationCollectionPath
    /// == nil`, "Individual postcards") — to this platform's app-owned bare-card location, and
    /// registers it as a source so it shows up immediately (`SinglePostcardsGridView` refreshes
    /// off `sources`, which this mutates via `addSource(for:)`). Returns the path actually
    /// written to, which may differ from `filename` if it collided (see `uniqueURL(for:in:)`).
    func addBareCard(filename: String, data: Data) throws -> String {
        #if os(macOS)
        let directory = bareCardsDirectory
        #else
        let directory = importDirectory
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = Self.uniqueURL(for: filename, in: directory)
        try data.write(to: url)

        #if os(macOS)
        rememberBookmark(for: url)
        #endif
        addSource(for: url)
        return url.path
    }

    /// Appends " 2", " 3", … before the known `.postcard.*` suffix until `directory` has no
    /// file at that name — e.g. `"card.postcard.jpg"` colliding becomes `"card 2.postcard.jpg"`,
    /// not `"card.postcard 2.jpg"`.
    private static func uniqueURL(for filename: String, in directory: URL) -> URL {
        let suffix = cardSuffixes.first { filename.lowercased().hasSuffix($0) } ?? ""
        let stem = String(filename.dropLast(suffix.count))
        var candidate = filename
        var attempt = 1
        while FileManager.default.fileExists(atPath: directory.appending(path: candidate).path) {
            attempt += 1
            candidate = "\(stem) \(attempt)\(suffix)"
        }
        return directory.appending(path: candidate)
    }

    private func addSource(for url: URL) {
        let name = Self.displayName(for: url)
        if isCollectionFile(url) {
            upsert(.collection(path: url.path, displayName: name))
        } else {
            upsert(.cardFile(path: url.path, displayName: name))
        }
    }

    #if os(macOS)

    // MARK: - Open in place (macOS)

    private func openInPlace(_ url: URL) async throws {
        let filename = url.lastPathComponent
        guard Self.knownSuffixes.contains(where: { filename.lowercased().hasSuffix($0) }) else {
            throw ImportError(errorDescription: "Not a postcard file (expected \(Self.knownSuffixes.joined(separator: ", "))).")
        }
        // Validate it opens via the Go core at its real path, so a corrupt/non-postcard file is
        // reported now instead of leaving a dead grid.
        if isCollectionFile(url) {
            _ = try await GoCore.shared.cardSummaries(inCollectionAt: url.path)
        } else {
            _ = try await GoCore.shared.summary(ofCardFileAt: url.path)
        }
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
    /// whose file can no longer be found. Rewrites the stored set so the drops/refreshes persist.
    private func restoreBookmarkedSources() {
        var kept: [Data] = []
        var seen = Set<String>()
        for bookmark in loadBookmarks() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                continue // file gone — drop it
            }
            guard seen.insert(url.path).inserted else { continue } // de-duplicate by resolved path
            kept.append(stale ? (makeBookmark(for: url) ?? bookmark) : bookmark)
            addSource(for: url)
        }
        saveBookmarks(kept)
    }

    #else

    // MARK: - Copy into container (iOS)

    private func copyIntoContainer(_ url: URL) async throws -> URL {
        let filename = url.lastPathComponent
        guard Self.knownSuffixes.contains(where: { filename.lowercased().hasSuffix($0) }) else {
            throw ImportError(errorDescription: "Not a postcard file (expected \(Self.knownSuffixes.joined(separator: ", "))).")
        }

        let destination = importDirectory.appending(path: filename)
        let directory = importDirectory

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
            if isCollectionFile(url) {
                _ = try await GoCore.shared.cardSummaries(inCollectionAt: url.path)
            } else {
                _ = try await GoCore.shared.summary(ofCardFileAt: url.path)
            }
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
            let filename = url.lastPathComponent.lowercased()
            if filename.hasSuffix(Self.collectionSuffix) || Self.cardSuffixes.contains(where: filename.hasSuffix) {
                addSource(for: url)
            }
        }
    }

    #endif
}
