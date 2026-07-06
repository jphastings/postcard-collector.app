import Foundation

/// Turns a user-entered collection title into a `.postcards` filename for the
/// "New collection…" flow. The title itself is stored verbatim inside the collection (see
/// `GoCore.createCollection(at:title:)`); only the filename needs sanitizing.
enum CollectionNaming {
    static let fallbackStem = "Untitled"

    static func filename(forTitle title: String) -> String {
        stem(forTitle: title) + ".postcards"
    }

    /// The filename minus its extension: path separators and `:` (Finder's legacy
    /// separator) become "-", control characters are dropped, whitespace is trimmed, and
    /// leading dots are stripped so the file can never be hidden. An empty result falls
    /// back to `fallbackStem`.
    static func stem(forTitle title: String) -> String {
        var stem = String(
            title
                .unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) }
                .map { "/\\:".unicodeScalars.contains($0) ? "-" : Character($0) }
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        while stem.hasPrefix(".") {
            stem.removeFirst()
        }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)

        return stem.isEmpty ? fallbackStem : stem
    }
}
