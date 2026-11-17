import Foundation

/// One thing the library's sidebar can show: an opened `.postcards` collection, an Atmosphere
/// account's collection (read-only, browsed from its cached copy), or the synthetic
/// "All collections" row. Bare `.postcard.*` files are never library sources —
/// they open in their own single-postcard window (see `SinglePostcardView`).
enum LibrarySource: Identifiable, Hashable {
    case collection(path: String, displayName: String)
    /// The cached copy of an org.dotpostcard.collection record at `uri`.
    case atprotoCollection(uri: String, path: String, displayName: String)
    /// Not a real file: the sidebar's pinned first row, showing the union of every card
    /// from every collection at once (see `AllCollectionsView`).
    case allCollections

    var id: String { path }

    var path: String {
        switch self {
        case .collection(let path, _): return path
        case .atprotoCollection(_, let path, _): return path
        case .allCollections: return "all-collections://aggregate"
        }
    }

    var displayName: String {
        switch self {
        case .collection(_, let name): return name
        case .atprotoCollection(_, _, let name): return name
        case .allCollections: return "All collections"
        }
    }

    var isCollection: Bool {
        if case .collection = self { return true }
        return false
    }

    /// Whether cards can be added to, moved out of and removed from it. Never an Atmosphere
    /// collection, which mirrors someone's records.
    var isWritable: Bool { isCollection }
}

/// One collection a card can be moved/copied into — the "known writable collections" list
/// for the grid cells' "Move to Collection…"/"Copy to Collection…" submenus. Built fresh
/// from `LibraryModel.sources` and `CloudLibrary.items` (imported + fully-downloaded
/// iCloud collections only) each time `LibraryView` renders.
struct WritableCollection: Identifiable, Hashable {
    var path: String
    var displayName: String

    var id: String { path }

    /// Every collection the app currently knows about — imported `LibrarySource`s plus
    /// `downloaded` (already-downloaded collections from elsewhere, e.g. iCloud) —
    /// deduplicated by path. Shared by `LibraryView`'s "Move to Collection…"/"Copy to
    /// Collection…" menus and the create-postcard flow's destination picker, so both build
    /// the identical list from the identical rule. A just-created iCloud collection can
    /// briefly appear in both `sources` (registered for instant visibility) and `downloaded`,
    /// hence the dedup.
    ///
    /// Takes `downloaded` as plain `WritableCollection`s — already filtered/mapped by the
    /// caller (see `LibraryView.writableCollections`) — rather than `CloudItem` directly, so
    /// this stays usable from targets that don't compile `CloudLibrary.swift` (watchOS, the
    /// QuickLook extensions both list `LibrarySource.swift` as an explicit source).
    static func known(sources: [LibrarySource], downloaded: [WritableCollection]) -> [WritableCollection] {
        var collections = sources.compactMap { source -> WritableCollection? in
            guard case .collection(let path, let name) = source else { return nil }
            return WritableCollection(path: path, displayName: name)
        }
        collections += downloaded

        var seen = Set<String>()
        return collections.filter { seen.insert($0.path).inserted }
    }
}

/// Which of the two card-transfer context-menu actions a "New collection…" prompt should
/// perform once the collection exists.
enum CardTransferAction {
    case move
    case copy
}

/// A single card, addressable back to the source it came from — either one card among
/// many in a collection, or the sole card in a bare file. `Sendable` because it crosses into
/// `PostcardFileExport`'s async, `@Sendable` `Transferable` export closure (see that type).
enum CardReference: Identifiable, Hashable, Sendable {
    case inCollection(path: String, summary: CardSummary)
    case bareFile(path: String, summary: CardSummary)

    var id: String {
        switch self {
        case .inCollection(let path, let summary): return "\(path)#\(summary.name)"
        case .bareFile(let path, _): return path
        }
    }

    var summary: CardSummary {
        switch self {
        case .inCollection(_, let summary): return summary
        case .bareFile(_, let summary): return summary
        }
    }

    /// The path of the file this card lives in — the collection file, or the bare file
    /// itself.
    var sourcePath: String {
        switch self {
        case .inCollection(let path, _): return path
        case .bareFile(let path, _): return path
        }
    }

    /// Classifies a cross-source `LibraryHit` back into a reference by its source path's
    /// extension — the same `.postcards` vs bare-file distinction `LibraryModel` uses.
    init(hit: LibraryHit) {
        if hit.source.lowercased().hasSuffix(".postcards") {
            self = .inCollection(path: hit.source, summary: hit.card)
        } else {
            self = .bareFile(path: hit.source, summary: hit.card)
        }
    }
}
