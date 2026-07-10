import SwiftUI

/// The content pane for the sidebar's synthetic "All collections" row: the union of every
/// card from every known source — collections and Single-postcards bare files alike — in
/// the same masonry grid / map UI the per-collection views use. The sidebar picks the
/// SCOPE; this pane lists the matching postcards; the detail pane shows the tapped one.
///
/// Search fans out through the Go `Library` (`GoCore.searchLibrary` — the same sources
/// `LibraryView` keeps synced), so descriptions and transcriptions match exactly as they
/// do in a single collection's FTS search; without a query it's a plain union listing.
struct AllCollectionsView: View {
    /// Paths of every known, openable collection (imported + fully-downloaded iCloud).
    let collectionPaths: [String]
    /// Paths of every known bare `.postcard.*` file.
    let barePaths: [String]
    @Binding var selection: CardReference?
    let cloudLibrary: CloudLibrary

    /// The full union; `nil` until the first load completes.
    @State private var entries: [MapCardEntry]?
    /// `nil` while no search is active; the Go-side hits otherwise.
    @State private var searchResults: [MapCardEntry]?
    @State private var searchText = ""
    @State private var viewMode = CollectionViewMode.grid
    /// Whether ANY card anywhere has a coordinate — gates `CollectionModeSwitcher`.
    /// Computed from the full union load, never search results.
    @State private var hasAnyLocation = false
    @State private var loadError: String?

    private struct SourcesKey: Equatable {
        var collections: [String]
        var bare: [String]
    }

    /// What both the grid and the map show: search hits while a query is active, the full
    /// union otherwise — map pins are filtered by search exactly like grid cells.
    private var displayedEntries: [MapCardEntry]? {
        searchText.isEmpty ? entries : searchResults
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Couldn't load postcards", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if let displayedEntries {
                if viewMode == .map {
                    CollectionMapView(entries: displayedEntries.filter { $0.summary.coordinate != nil }, selection: $selection)
                } else if displayedEntries.isEmpty {
                    emptyState
                } else {
                    MasonryGrid(items: displayedEntries, aspectRatio: { Double($0.summary.frontPxW) / Double(max($0.summary.frontPxH, 1)) }) { entry in
                        Button {
                            selection = entry.reference
                        } label: {
                            UnionGridCell(entry: entry, isSelected: selection == entry.reference)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("All collections")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CollectionModeSwitcher(mode: $viewMode, isEnabled: hasAnyLocation)
            }
        }
        .searchable(text: $searchText, prompt: "Search all collections")
        .task(id: SourcesKey(collections: collectionPaths, bare: barePaths)) { await loadUnion() }
        .task(id: searchText) { await search() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            ContentUnavailableView("No Postcards", systemImage: "photo.stack")
        } else {
            ContentUnavailableView.search
        }
    }

    private func loadUnion() async {
        loadError = nil
        var union: [MapCardEntry] = []
        for path in collectionPaths {
            do {
                try await primeIfCloudBacked(path)
                let summaries = try await GoCore.shared.cardSummaries(inCollectionAt: path)
                union += summaries.map { MapCardEntry(summary: $0, reference: .inCollection(path: path, summary: $0)) }
            } catch {
                // One unreadable source shouldn't blank the union; its cards just won't appear.
                continue
            }
        }
        for path in barePaths {
            do {
                try await primeIfCloudBacked(path)
                let summary = try await GoCore.shared.summary(ofCardFileAt: path)
                union.append(MapCardEntry(summary: summary, reference: .bareFile(path: path, summary: summary)))
            } catch {
                continue
            }
        }
        entries = union
        hasAnyLocation = CollectionMapGating.isEnabled(for: union.map(\.summary))
    }

    private func search() async {
        guard !searchText.isEmpty else {
            searchResults = nil
            return
        }
        do {
            let hits = try await GoCore.shared.searchLibrary(query: searchText)
            searchResults = MapCardEntry.entries(fromHits: hits)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func primeIfCloudBacked(_ path: String) async throws {
        if cloudLibrary.items.contains(where: { $0.path == path }) {
            try await CloudLibrary.primeForGoCore(path: path)
        }
    }
}

/// A thumbnail cell that works for either kind of reference: collection cards use the Go
/// core's pre-generated thumbnail (like `GridCell`), bare files split the full image's
/// front (like `BareGridCell`) — both through the same `ThumbnailCache` keys those cells
/// use, so nothing already cached is decoded twice. No context menu here: move/copy/remove
/// actions belong to the per-source views, where "which collection is this card in" is
/// unambiguous.
private struct UnionGridCell: View {
    let entry: MapCardEntry
    var isSelected: Bool = false

    @State private var thumbnail: PlatformImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(platformImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .aspectRatio(CGFloat(entry.summary.frontPxW) / CGFloat(max(entry.summary.frontPxH, 1)), contentMode: .fit)
        .contentShape(Rectangle())
        .thumbnailHoverParallax()
        .gridSelectionHighlight(isSelected, image: thumbnail)
        .accessibilityLabel(entry.summary.name)
        .accessibilityIdentifier(entry.summary.name)
        .task(id: entry.id) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        switch entry.reference {
        case .inCollection(let path, _):
            let cacheKey = "\(path)#\(entry.summary.name)"
            if let cached = ThumbnailCache.shared.image(forKey: cacheKey) {
                thumbnail = cached
                return
            }
            do {
                let data = try await GoCore.shared.thumbnail(forCard: entry.summary.name, inCollectionAt: path)
                guard let image = PlatformImage(data: data) else { return }
                ThumbnailCache.shared.set(image, forKey: cacheKey)
                thumbnail = image
            } catch {
                // Leave the placeholder; one cell's failure shouldn't disrupt the grid.
            }
        case .bareFile(let path, _):
            let cacheKey = "\(path)#thumbnail"
            if let cached = ThumbnailCache.shared.image(forKey: cacheKey) {
                thumbnail = cached
                return
            }
            do {
                let data = try await GoCore.shared.image(ofCardFileAt: path)
                let flip = entry.summary.flip
                let front = try await Task.detached(priority: .utility) {
                    try ImageSplitter.split(data: data, flip: flip).front
                }.value
                let image = PlatformImage.from(cgImage: front)
                ThumbnailCache.shared.set(image, forKey: cacheKey)
                thumbnail = image
            } catch {
                // Same: leave the placeholder.
            }
        }
    }
}
