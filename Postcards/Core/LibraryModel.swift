import Foundation
import Observation

/// The set of sources shown in `LibraryView`: the bundled fixture collection/card plus
/// anything opened via the file importer. Deliberately not persisted across launches yet
/// (that's iCloud/bookmark territory — out of scope for this milestone).
@Observable
final class LibraryModel {
    private(set) var sources: [LibrarySource] = []

    init() {
        if let fixtureCollection = Bundle.main.url(forResource: "fixture.postcard", withExtension: "db") {
            sources.append(.collection(path: fixtureCollection.path, displayName: "Sample Collection"))
        }
        if let fixtureCard = Bundle.main.url(forResource: "righthand-card.postcard", withExtension: "jpeg") {
            sources.append(.cardFile(path: fixtureCard.path, displayName: Self.displayName(for: fixtureCard)))
        }
    }

    /// Adds sources picked via `.fileImporter`, ignoring ones already present.
    func addSources(from urls: [URL]) {
        for url in urls {
            // Files outside the app's own container arrive as security-scoped URLs; the
            // access grant must stay open for as long as the Go core might read the file.
            _ = url.startAccessingSecurityScopedResource()

            guard !sources.contains(where: { $0.path == url.path }) else { continue }

            let name = Self.displayName(for: url)
            if url.pathExtension.lowercased() == "db" {
                sources.append(.collection(path: url.path, displayName: name))
            } else {
                sources.append(.cardFile(path: url.path, displayName: name))
            }
        }
    }

    private static let knownSuffixes = [".postcard.db", ".postcard.webp", ".postcard.jpg", ".postcard.jpeg", ".postcard.png"]

    private static func displayName(for url: URL) -> String {
        let filename = url.lastPathComponent
        for suffix in knownSuffixes where filename.hasSuffix(suffix) {
            return String(filename.dropLast(suffix.count))
        }
        return url.deletingPathExtension().lastPathComponent
    }
}
