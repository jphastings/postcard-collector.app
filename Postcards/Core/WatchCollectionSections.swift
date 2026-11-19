import Foundation

/// One section of the watch's collection list. The watch gets everything through the iPhone,
/// but lists it in the iPhone sidebar's sections so collections are where the person expects
/// them. Pure, so it's unit-testable; `WatchCollectionListView` just renders it.
struct WatchCollectionSection: Equatable, Identifiable {
    var title: String
    var collections: [WatchCollectionInfo]

    var id: String { title }

    /// The catalog grouped into "From iPhone" (only on the phone), "iCloud" — which includes
    /// entries from phones too old to say where they come from — and "Atmosphere" (own, then
    /// followed), each by title. Empty sections are left out.
    static func sections(of catalog: [WatchCollectionInfo]) -> [WatchCollectionSection] {
        let byTitle = catalog.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return [
            WatchCollectionSection(title: "From iPhone", collections: byTitle.filter { $0.isLocal == true }),
            WatchCollectionSection(title: "iCloud", collections: byTitle.filter { $0.isLocal != true && $0.atmosphere == nil }),
            WatchCollectionSection(
                title: "Atmosphere",
                collections: byTitle.filter { $0.atmosphere == .own } + byTitle.filter { $0.atmosphere == .followed }
            ),
        ].filter { !$0.collections.isEmpty }
    }
}
