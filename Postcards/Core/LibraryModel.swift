import Foundation
import Observation

/// The set of sources shown in `LibraryView`: whatever the user has opened (file importer,
/// ⌘O, drag-and-drop, or Open With). There's nothing bundled — a fresh install starts
/// empty (see `LibraryView`'s empty-library state).
///
/// Imported files are **copied into the app's own container** (Application
/// Support/ImportedSources) and the copy is opened, rather than holding the original's
/// security-scoped URL open. Chosen over security-scoped bookmarks because:
/// - the sandbox grant on a picker URL is tied to that URL instance's lifetime, which is
///   easy to get subtly wrong (the previous implementation dropped the URL after
///   `startAccessingSecurityScopedResource()`, revoking the Go core's read access to the
///   SQLite file mid-session — a dead grid);
/// - the Go core holds the SQLite file open indefinitely, an awkward fit for
///   scoped-access lifetimes, iCloud eviction, and provider-mediated reads;
/// - copies survive relaunch for free (rescanned at startup).
/// The trade-off — the copy doesn't track later changes to the original — is fine for a
/// read-only viewer of files authored by a CLI.
@MainActor
@Observable
final class LibraryModel {
    private(set) var sources: [LibrarySource] = []

    /// The most recent import failure, for the UI to surface as an alert. Never leave a
    /// dead grid: anything that stops a picked file from opening ends up here.
    var importError: String?

    private let importDirectory: URL

    nonisolated static var defaultImportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "ImportedSources", directoryHint: .isDirectory)
    }

    init(importDirectory: URL = LibraryModel.defaultImportDirectory) {
        self.importDirectory = importDirectory
        restorePreviousImports()
    }

    /// Copies each picked file into the app container, validates it opens via the Go
    /// core, and adds it as a source. Shared by every entry point on both platforms:
    /// file importer, macOS ⌘O open panel, drag-and-drop, and onOpenURL.
    func importSources(from urls: [URL]) async {
        var failures: [String] = []

        for url in urls {
            do {
                let copied = try await copyIntoContainer(url)
                try await addValidatedSource(at: copied)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !failures.isEmpty {
            importError = failures.joined(separator: "\n")
        }
    }

    // MARK: - Import pipeline

    private static let collectionSuffix = ".postcards"
    // ".postcard" (bare) is listed last: it's a suffix of every other entry here
    // (".postcard.webp".hasSuffix(".postcard")` is false, but checking order still matters
    // for any future compound suffix that literally ends in ".postcard"), so keeping it
    // last means the more specific compound suffixes always get first refusal.
    private static let cardSuffixes = [".postcard.webp", ".postcard.jpg", ".postcard.jpeg", ".postcard.png", ".postcard"]
    private static let knownSuffixes = [collectionSuffix] + cardSuffixes

    private struct ImportError: LocalizedError {
        let errorDescription: String?
    }

    /// Copies `url` into the import directory (replacing any previous import of the same
    /// filename, so re-importing picks up a newer version). The security-scope dance
    /// happens entirely inside this function, bracketing the one read we need: the copy.
    private func copyIntoContainer(_ url: URL) async throws -> URL {
        let filename = url.lastPathComponent
        guard Self.knownSuffixes.contains(where: { filename.lowercased().hasSuffix($0) }) else {
            throw ImportError(errorDescription: "Not a postcard file (expected \(Self.knownSuffixes.joined(separator: ", "))).")
        }

        let destination = importDirectory.appending(path: filename)
        let directory = importDirectory

        // If a previous import of this filename is open in the Go core, close it before
        // replacing the file underneath it.
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
            // NSFileCoordinator materialises provider-backed files (e.g. undownloaded
            // iCloud Drive items) before we read, instead of failing or blocking the copy.
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

    /// Opens the copied file via the Go core before adding it, so a corrupt or
    /// non-postcard file is reported at import time instead of leaving a dead grid.
    /// A copy that fails validation is deleted, so it can't be "restored" as a broken
    /// source on the next launch.
    private func addValidatedSource(at url: URL) async throws {
        let path = url.path
        let name = Self.displayName(for: url)

        do {
            if url.lastPathComponent.lowercased().hasSuffix(Self.collectionSuffix) {
                _ = try await GoCore.shared.cardSummaries(inCollectionAt: path)
                upsert(.collection(path: path, displayName: name))
            } else {
                _ = try await GoCore.shared.summary(ofCardFileAt: path)
                upsert(.cardFile(path: path, displayName: name))
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Adds a just-created collection file (the "New collection…" flow) as a source
    /// immediately — unlike `importSources` there's nothing to copy or validate, because
    /// the file was created in place by `GoCore.createCollection` a moment ago.
    func registerCollection(at url: URL) {
        upsert(.collection(path: url.path, displayName: Self.displayName(for: url)))
    }

    private func upsert(_ source: LibrarySource) {
        if let existing = sources.firstIndex(where: { $0.path == source.path }) {
            sources[existing] = source
        } else {
            sources.append(source)
        }
    }

    /// Drops the source at `path` from the list — used by "Remove from Library"/"Delete…"
    /// once the underlying file (and any cached Go core handle) is gone. A no-op if `path`
    /// isn't a known source (e.g. it was never imported, only synced in from iCloud).
    func remove(path: String) {
        sources.removeAll { $0.path == path }
    }

    /// Re-adds everything previously copied into the import directory. Files were
    /// validated when first imported; anything that has since gone bad fails visibly in
    /// the grid (`CollectionGridView` surfaces load errors) rather than at launch.
    private func restorePreviousImports() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: importDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let filename = url.lastPathComponent.lowercased()
            if filename.hasSuffix(Self.collectionSuffix) {
                upsert(.collection(path: url.path, displayName: Self.displayName(for: url)))
            } else if Self.cardSuffixes.contains(where: filename.hasSuffix) {
                upsert(.cardFile(path: url.path, displayName: Self.displayName(for: url)))
            }
        }
    }

    private static func displayName(for url: URL) -> String {
        let filename = url.lastPathComponent
        for suffix in knownSuffixes where filename.lowercased().hasSuffix(suffix) {
            return String(filename.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
