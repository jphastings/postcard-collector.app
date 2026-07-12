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
    /// Search presets submitted from elsewhere (e.g. a person's "More from…" context menu in
    /// `CardInfoPanel`) land here — see `applySearchPreset()`, hung off
    /// `.onChange(of: searchRequest.generation)` below.
    let searchRequest: SearchRequest

    /// The full union; `nil` until the first load completes.
    @State private var entries: [MapCardEntry]?
    /// `nil` while no search is active; the Go-side hits otherwise.
    @State private var searchResults: [MapCardEntry]?
    @State private var searchText = ""
    /// Active search-bar pills (people/country/date), alongside `searchText`'s free text —
    /// see `SearchToken`.
    @State private var searchTokens: [SearchToken] = []
    /// Every known person across the library's registered sources, for search-token
    /// suggestions (see `SearchSuggestions`).
    @State private var people: [PersonRef] = []
    @State private var viewMode = CollectionViewMode.grid
    #if os(iOS)
    @FocusState private var isSearchFieldFocused: Bool
    #else
    /// Flipped to `true` to ask `BottomSearchBar` to focus its field (e.g. after a search
    /// preset lands); it flips this back to `false` once done.
    @State private var focusSearchFieldRequest = false
    #endif
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
    ///
    /// Falls back to `entries` while a just-started query's own `.task(id:)` hasn't resolved
    /// yet, rather than going `nil`: `searchResults` only starts life as `nil` and isn't
    /// filled in until `search()`'s Go-core call returns, so without this fallback the very
    /// first keystroke into an empty field would flip this `nil` for a frame — swapping the
    /// pane's `Group` out of its `ZStack` branch into the loading `ProgressView()` branch,
    /// which (per the comment on that `ZStack` below) is exactly the kind of view-identity
    /// churn that drops `BottomSearchBar`'s focus.
    private var displayedEntries: [MapCardEntry]? {
        (searchText.isEmpty && searchTokens.isEmpty) ? entries : (searchResults ?? entries)
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Couldn't load postcards", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if let displayedEntries {
                if viewMode == .map {
                    CollectionMapView(entries: displayedEntries.filter { $0.summary.coordinate != nil }, selection: $selection)
                } else {
                    // The grid stays mounted (just laid out with zero items) rather than
                    // being replaced by `emptyState` outright: swapping the whole
                    // `ScrollView`-backed `MasonryGrid` out for an entirely different view on
                    // every keystroke that narrows results to zero was what dropped the
                    // search field's focus (see `BottomSearchBar`'s call site below) —
                    // keeping one stable, always-mounted grid instance and only overlaying
                    // the empty-state message removes that churn.
                    ZStack {
                        MasonryGrid(items: displayedEntries, aspectRatio: { Double($0.summary.frontPxW) / Double(max($0.summary.frontPxH, 1)) }) { entry in
                            Button {
                                selection = entry.reference
                            } label: {
                                UnionGridCell(entry: entry, isSelected: selection == entry.reference)
                            }
                            .buttonStyle(.plain)
                        }
                        if displayedEntries.isEmpty {
                            emptyState
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .collectionModeSwitcherOverlay(mode: $viewMode, isEnabled: hasAnyLocation)
        .navigationTitle("All collections")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CollectionModeSwitcher(mode: $viewMode, isEnabled: hasAnyLocation)
            }
        }
        #endif
        #if os(macOS)
        .bottomSearchBar(
            text: $searchText,
            tokens: $searchTokens,
            suggestions: suggestedTokens,
            onPickSuggestion: acceptSuggestion,
            prompt: "Search all collections",
            focusRequest: $focusSearchFieldRequest
        )
        #else
        .searchable(
            text: $searchText,
            tokens: $searchTokens,
            prompt: "Search all collections",
            token: { Text($0.pillLabel) }
        )
        // iOS ignores the `suggestedTokens:` binding in this configuration (it renders fine
        // on macOS); the reliable iOS path is searchSuggestions rows whose searchCompletion
        // converts a tapped row into a token and clears the typed fragment — the Mail model.
        .searchSuggestions {
            ForEach(suggestedTokens) { token in
                Label(token.pillLabel, systemImage: token.suggestionSymbol)
                    .searchCompletion(token)
            }
        }
        .modifier(SearchFocusedIfAvailable(binding: $isSearchFieldFocused))
        #endif
        .task(id: SourcesKey(collections: collectionPaths, bare: barePaths)) { await loadUnion() }
        .task(id: SourcesKey(collections: collectionPaths, bare: barePaths)) { await loadPeople() }
        .task(id: SearchInputKey(text: searchText, tokens: searchTokens)) { await search() }
        .onChange(of: searchText) { _, newValue in promoteTypedTokens(from: newValue) }
        .onChange(of: searchRequest.generation) { _, _ in applySearchPreset() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty, searchTokens.isEmpty {
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
        let query = SearchQuery.from(tokens: searchTokens, freeText: searchText)
        guard !(query.isPlainText && query.text.isEmpty) else {
            searchResults = nil
            return
        }
        do {
            let hits: [LibraryHit]
            if query.isPlainText {
                hits = try await GoCore.shared.searchLibrary(query: searchText)
            } else {
                hits = try await GoCore.shared.searchLibraryFiltered(filter: query)
            }
            searchResults = MapCardEntry.entries(fromHits: hits)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadPeople() async {
        people = (try? await GoCore.shared.libraryPeople()) ?? []
    }

    private var suggestedTokens: [SearchToken] {
        SearchSuggestions.suggestions(for: searchText, people: people, existingTokens: searchTokens)
    }

    /// Converts any complete `tag:value` expression just typed into a pill, leaving whatever
    /// text is still mid-typing behind — see `SearchToken.promote(from:)`.
    private func promoteTypedTokens(from text: String) {
        let (promoted, remainder) = SearchToken.promote(from: text)
        guard !promoted.isEmpty else { return }
        appendTokens(promoted)
        searchText = remainder
    }

    /// Picks up the latest search preset from `CardInfoPanel`'s "More from…" menu (routed
    /// through `SearchRequest`): appends it as a pill, clears any in-progress free text, and
    /// focuses the search field so the user sees where the new pill landed.
    private func applySearchPreset() {
        guard let token = searchRequest.token else { return }
        appendTokens([token])
        searchText = ""
        #if os(iOS)
        isSearchFieldFocused = true
        #else
        focusSearchFieldRequest = true
        #endif
    }

    private func appendTokens(_ tokens: [SearchToken]) {
        let existingIDs = Set(searchTokens.map(\.id))
        searchTokens.append(contentsOf: tokens.filter { !existingIDs.contains($0.id) })
    }

    #if os(macOS)
    /// A suggestion tapped in `BottomSearchBar`'s floating list: appends its token and
    /// strips the fragment it was suggested from out of `searchText` (the engine computed
    /// the suggestion from that fragment, so it's already accounted for as a pill).
    private func acceptSuggestion(_ token: SearchToken) {
        appendTokens([token])
        searchText = strippingTrailingFragment(from: searchText)
    }

    /// Drops the raw, as-typed trailing whitespace-separated fragment from `text` — mirrors
    /// `SearchSuggestions`'s own trailing-fragment scan (which is what a suggestion is
    /// computed from), re-quoting any fragment left behind that still needs it so re-parsing
    /// isn't affected.
    private func strippingTrailingFragment(from text: String) -> String {
        var fragments = SearchQuery.tokenize(text)
        guard !fragments.isEmpty else { return text }
        fragments.removeLast()
        return fragments.map { $0.contains(where: \.isWhitespace) ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
    #endif

    private func primeIfCloudBacked(_ path: String) async throws {
        if cloudLibrary.items.contains(where: { $0.path == path }) {
            try await CloudLibrary.primeForGoCore(path: path)
        }
    }
}

/// `.task(id:)` key for re-running search when EITHER the free text or the active pills
/// change.
private struct SearchInputKey: Equatable {
    var text: String
    var tokens: [SearchToken]
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
        .draggablePostcard(entry.reference)
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
