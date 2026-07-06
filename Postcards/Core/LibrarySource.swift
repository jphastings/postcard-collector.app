import Foundation

/// One thing the library can show: either an opened `.postcards` collection, a bare
/// `.postcard.*` file opened outside of any collection, or the synthetic "Single postcards"
/// aggregate row (see `SinglePostcardsGridView`) standing in for every bare file at once.
enum LibrarySource: Identifiable, Hashable {
    case collection(path: String, displayName: String)
    case cardFile(path: String, displayName: String)
    /// Not a real file — `LibraryView` never puts this in `LibraryModel.sources` or
    /// `CloudLibrary.items`; it only ever appears as the sidebar's pinned last row, so it
    /// can be `List(selection:)`'s tag like any other source.
    case singlePostcards
    /// Also synthetic: the sidebar's pinned FIRST row, showing the union of every card
    /// from every known source at once (see `AllCollectionsView`).
    case allCollections

    var id: String { path }

    var path: String {
        switch self {
        case .collection(let path, _): return path
        case .cardFile(let path, _): return path
        case .singlePostcards: return "single-postcards://aggregate"
        case .allCollections: return "all-collections://aggregate"
        }
    }

    var displayName: String {
        switch self {
        case .collection(_, let name): return name
        case .cardFile(_, let name): return name
        case .singlePostcards: return "Single postcards"
        case .allCollections: return "All collections"
        }
    }

    var isCollection: Bool {
        if case .collection = self { return true }
        return false
    }
}

/// One collection a card can be moved/copied into — the "known writable collections" list
/// for the grid cells' "Move to Collection…"/"Copy to Collection…" submenus. Built fresh
/// from `LibraryModel.sources` and `CloudLibrary.items` (imported + fully-downloaded
/// iCloud collections only) each time `LibraryView` renders.
struct WritableCollection: Identifiable, Hashable {
    var path: String
    var displayName: String

    var id: String { path }
}

/// Which of the two card-transfer context-menu actions a "New collection…" prompt should
/// perform once the collection exists.
enum CardTransferAction {
    case move
    case copy
}

/// A single card, addressable back to the source it came from — either one card among
/// many in a collection, or the sole card in a bare file.
enum CardReference: Identifiable, Hashable {
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
