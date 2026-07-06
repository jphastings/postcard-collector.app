import Foundation

/// One card in an aggregate listing (map pins, the All-collections grid), paired with the
/// `CardReference` that opens it in `CardDetailView` — `CollectionGridView` builds these as
/// `.inCollection`, `SinglePostcardsGridView` as `.bareFile`, which is the only thing that
/// differs between the call sites (see `GoCore.image(for:)`/`metadata(for:)`, which already
/// abstract over both kinds of reference).
struct MapCardEntry: Identifiable, Hashable {
    var summary: CardSummary
    var reference: CardReference

    var id: String { reference.id }
}

extension MapCardEntry {
    /// Reassembles a cross-source `Library` search hit into an entry, classifying it back
    /// into a collection or bare-file reference by its source path (see `CardReference`).
    init(hit: LibraryHit) {
        self.init(summary: hit.card, reference: CardReference(hit: hit))
    }

    static func entries(fromHits hits: [LibraryHit]) -> [MapCardEntry] {
        hits.map(MapCardEntry.init(hit:))
    }
}
