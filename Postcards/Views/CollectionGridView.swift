import SwiftUI

/// Process-wide cache of decoded thumbnails, keyed by `"<source path>#<card name>"`.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, PlatformImage>()

    func image(forKey key: String) -> PlatformImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: PlatformImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// A masonry grid of every card in one collection, searchable via the collection's FTS
/// index (the Go core's one definition of searchable text: names, people, locations,
/// descriptions, transcriptions, context). Cross-source search lives with the sidebar's
/// "All collections" row (see `AllCollectionsView`), not here — the sidebar picks the
/// scope, this pane lists the matches. Cell aspect ratios come from
/// `CardSummary.frontPxW/H` alone, so the grid lays itself out without decoding images.
struct CollectionGridView: View {
    let source: LibrarySource
    @Binding var selection: CardReference?
    /// Every collection a card can be moved/copied into (Feature 4), for the grid cells'
    /// context menus — excludes this collection itself at the point of use.
    var writableCollections: [WritableCollection] = []
    let cloudLibrary: CloudLibrary
    /// Search presets submitted from elsewhere (e.g. a person's "More from…" context menu in
    /// `CardInfoPanel`) land here — see `applySearchPreset()`, hung off
    /// `.onChange(of: searchRequest.generation)` below.
    let searchRequest: SearchRequest
    /// Creates a new, empty collection for the context menus' "New collection…" action
    /// and returns it as a move/copy target — supplied by `LibraryView`, which owns where
    /// new collections live (iCloud vs local) and source registration.
    var onCreateCollection: ((String) async throws -> WritableCollection)?

    /// `nil` until the first load/search completes; distinguishes "still loading" from a
    /// collection or search that has genuinely returned zero cards.
    @State private var cards: [CardSummary]?
    @State private var title: String?
    @State private var searchText = ""
    /// Active search-bar pills (people/country/date), alongside `searchText`'s free text —
    /// see `SearchToken`.
    @State private var searchTokens: [SearchToken] = []
    /// This collection's known people, for search-token suggestions (see `SearchSuggestions`).
    @State private var people: [PersonRef] = []
    @State private var loadError: String?
    @State private var loadErrorTitle = "Couldn't open collection"
    @State private var actionError: String?
    @State private var viewMode = CollectionViewMode.grid
    #if os(iOS)
    @FocusState private var isSearchFieldFocused: Bool
    #else
    /// Flipped to `true` to ask `BottomSearchBar` to focus its field (e.g. after a search
    /// preset lands); it flips this back to `false` once done.
    @State private var focusSearchFieldRequest = false
    #endif
    /// Whether ANY card in the full, unfiltered collection has a coordinate — gates
    /// `CollectionModeSwitcher`. Only updated by `loadCards()` (never by `search()`, which
    /// can narrow `cards` to a search-filtered subset) so it always reflects the whole
    /// collection, not whatever's currently displayed.
    @State private var hasAnyLocation = false
    @State private var newCollectionPrompt: NewCollectionPrompt?
    @State private var newCollectionTitle = ""

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    loadErrorTitle,
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if viewMode == .map {
                if let cards {
                    CollectionMapView(entries: mapEntries(from: cards), selection: $selection)
                } else {
                    ProgressView()
                }
            } else if let cards {
                if cards.isEmpty {
                    emptyState
                } else {
                    MasonryGrid(items: cards, aspectRatio: { Double($0.frontPxW) / Double(max($0.frontPxH, 1)) }) { card in
                        Button {
                            selection = .inCollection(path: source.path, summary: card)
                        } label: {
                            GridCell(
                                source: source,
                                card: card,
                                isSelected: selection == .inCollection(path: source.path, summary: card),
                                writableCollections: writableCollections.filter { $0.path != source.path },
                                onCopy: { card, target in Task { await copyCard(card, to: target) } },
                                onMove: { card, target in Task { await moveCard(card, to: target) } },
                                onNewCollection: { card, action in promptForNewCollection(card: card, action: action) },
                                onRemove: { card in Task { await removeFromCollection(card) } }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title ?? source.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CollectionModeSwitcher(mode: $viewMode, isEnabled: hasAnyLocation)
            }
        }
        // Search narrows the same `cards` array both the grid and the map read from, so
        // map pins are filtered by an active search too.
        #if os(macOS)
        .bottomSearchBar(
            text: $searchText,
            tokens: $searchTokens,
            suggestions: suggestedTokens,
            onPickSuggestion: acceptSuggestion,
            prompt: "Search this collection",
            focusRequest: $focusSearchFieldRequest
        )
        #else
        .searchable(
            text: $searchText,
            tokens: $searchTokens,
            suggestedTokens: .constant(suggestedTokens),
            prompt: "Search this collection",
            token: { Text($0.pillLabel) }
        )
        .modifier(SearchFocusedIfAvailable(binding: $isSearchFieldFocused))
        #endif
        .task(id: source.id) { await loadCards() }
        .task(id: source.id) { await loadTitle() }
        .task(id: source.id) { await loadPeople() }
        .task(id: SearchInputKey(text: searchText, tokens: searchTokens)) { await search() }
        .onChange(of: searchText) { _, newValue in promoteTypedTokens(from: newValue) }
        .onChange(of: searchRequest.generation) { _, _ in applySearchPreset() }
        .alert(
            "Couldn't complete that action",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .newCollectionAlert(prompt: $newCollectionPrompt, title: $newCollectionTitle) { prompt, collectionTitle in
            await createCollectionAndTransfer(prompt, title: collectionTitle)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty, searchTokens.isEmpty {
            ContentUnavailableView("No Postcards", systemImage: "photo.stack")
        } else {
            ContentUnavailableView.search
        }
    }

    private func loadCards() async {
        loadError = nil
        do {
            let loaded = try await GoCore.shared.cardSummaries(inCollectionAt: source.path)
            cards = loaded
            hasAnyLocation = CollectionMapGating.isEnabled(for: loaded)
        } catch {
            loadErrorTitle = "Couldn't open collection"
            loadError = error.localizedDescription
        }
    }

    private func mapEntries(from cards: [CardSummary]) -> [MapCardEntry] {
        cards.compactMap { card in
            guard card.coordinate != nil else { return nil }
            return MapCardEntry(summary: card, reference: .inCollection(path: source.path, summary: card))
        }
    }

    private func loadTitle() async {
        if let fetched = try? await GoCore.shared.title(ofCollectionAt: source.path), !fetched.isEmpty {
            title = fetched
        }
    }

    private func search() async {
        let query = SearchQuery.from(tokens: searchTokens, freeText: searchText)
        guard !(query.isPlainText && query.text.isEmpty) else {
            await loadCards()
            return
        }
        loadError = nil
        do {
            if query.isPlainText {
                cards = try await GoCore.shared.search(inCollectionAt: source.path, query: searchText).map(\.card)
            } else {
                cards = try await GoCore.shared.searchFiltered(inCollectionAt: source.path, filter: query).map(\.card)
            }
        } catch {
            loadErrorTitle = "Search failed"
            loadError = error.localizedDescription
        }
    }

    private func loadPeople() async {
        people = (try? await GoCore.shared.people(inCollectionAt: source.path)) ?? []
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

    // MARK: - Card actions (Feature 4)

    private func isCloudBacked(_ path: String) -> Bool {
        cloudLibrary.items.contains { $0.path == path }
    }

    private func primeIfCloudBacked(_ path: String) async throws {
        if isCloudBacked(path) {
            try await CloudLibrary.primeForGoCoreWrite(path: path)
        }
    }

    private func copyCard(_ card: CardSummary, to target: WritableCollection) async {
        do {
            let data = try await GoCore.shared.image(forCard: card.name, inCollectionAt: source.path)
            try await primeIfCloudBacked(target.path)
            try await GoCore.shared.addCard(filename: card.filename, data: data, toCollectionAt: target.path)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func moveCard(_ card: CardSummary, to target: WritableCollection) async {
        do {
            try await primeIfCloudBacked(source.path)
            try await primeIfCloudBacked(target.path)
            try await GoCore.shared.moveCard(named: card.name, filename: card.filename, from: source.path, to: target.path)
            await loadCards()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func removeFromCollection(_ card: CardSummary) async {
        do {
            try await primeIfCloudBacked(source.path)
            try await GoCore.shared.removeCard(named: card.name, fromCollectionAt: source.path)
            await loadCards()
            if case .inCollection(let path, let summary) = selection, path == source.path, summary.name == card.name {
                selection = nil
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - New collection…

    private func promptForNewCollection(card: CardSummary, action: CardTransferAction) {
        newCollectionTitle = ""
        newCollectionPrompt = NewCollectionPrompt(card: card, action: action)
    }

    private func createCollectionAndTransfer(_ prompt: NewCollectionPrompt, title: String) async {
        guard let onCreateCollection else { return }
        do {
            let target = try await onCreateCollection(title)
            switch prompt.action {
            case .move: await moveCard(prompt.card, to: target)
            case .copy: await copyCard(prompt.card, to: target)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// `.task(id:)` key for re-running search when EITHER the free text or the active pills
/// change.
private struct SearchInputKey: Equatable {
    var text: String
    var tokens: [SearchToken]
}

/// The pending "New collection…" context-menu action: which card to transfer, and how,
/// once the user has entered a title.
struct NewCollectionPrompt {
    var card: CardSummary
    var action: CardTransferAction
    /// For bare-file sources only (`SinglePostcardsGridView`): the file the card lives in.
    var barePath: String?
}

extension View {
    /// The shared "New collection…" title prompt: an alert with a text field, run by both
    /// grid views. `perform` receives the pending transfer and the entered title.
    func newCollectionAlert(
        prompt: Binding<NewCollectionPrompt?>,
        title: Binding<String>,
        perform: @escaping (NewCollectionPrompt, String) async -> Void
    ) -> some View {
        alert(
            "New Collection",
            isPresented: Binding(get: { prompt.wrappedValue != nil }, set: { if !$0 { prompt.wrappedValue = nil } })
        ) {
            TextField("Title", text: title)
            Button("Create") {
                if let pending = prompt.wrappedValue {
                    let collectionTitle = title.wrappedValue
                    Task { await perform(pending, collectionTitle) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The postcard will be added to the new collection.")
        }
    }
}

/// A pure thumbnail: no background plate, no rounded-corner clipping, no name/sender
/// labels. Postcards can have real transparency (die-cut/torn scans), so a decorative
/// plate behind the image would show through as a fake rectangular border — the cell
/// shows only the card's own silhouette. `.contentShape(Rectangle())` keeps the whole
/// cell tappable over transparent regions, and the accessibility label carries the name
/// and description that used to be rendered as text.
private struct GridCell: View {
    let source: LibrarySource
    let card: CardSummary
    var isSelected: Bool = false
    var writableCollections: [WritableCollection] = []
    var onCopy: (CardSummary, WritableCollection) -> Void = { _, _ in }
    var onMove: (CardSummary, WritableCollection) -> Void = { _, _ in }
    var onNewCollection: (CardSummary, CardTransferAction) -> Void = { _, _ in }
    var onRemove: (CardSummary) -> Void = { _ in }

    @State private var thumbnail: PlatformImage?
    @State private var frontDescription: String?
    @State private var confirmingRemoval = false

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
        .aspectRatio(CGFloat(card.frontPxW) / CGFloat(max(card.frontPxH, 1)), contentMode: .fit)
        .contentShape(Rectangle())
        .thumbnailHoverParallax()
        .gridSelectionHighlight(isSelected, image: thumbnail)
        .accessibilityLabel(frontDescription ?? card.name)
        // Stable machine-facing handle for UI tests; the label above stays human-readable.
        .accessibilityIdentifier(card.name)
        .task(id: card.id) { await loadThumbnail() }
        .task(id: card.id) { await loadFrontDescription() }
        .contextMenu {
            Menu("Move to Collection…") {
                Button("New collection…") { onNewCollection(card, .move) }
                Divider()
                ForEach(writableCollections) { target in
                    Button(target.displayName) { onMove(card, target) }
                }
            }
            Menu("Copy to Collection…") {
                Button("New collection…") { onNewCollection(card, .copy) }
                Divider()
                ForEach(writableCollections) { target in
                    Button(target.displayName) { onCopy(card, target) }
                }
            }
            Divider()
            Button("Remove from Collection…", role: .destructive) { confirmingRemoval = true }
        }
        .confirmationDialog(
            "Remove “\(card.name)” from this collection?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { onRemove(card) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This card only exists in this collection — it will be gone unless you copy it elsewhere first.")
        }
    }

    private func loadThumbnail() async {
        let cacheKey = "\(source.path)#\(card.name)"
        if let cached = ThumbnailCache.shared.image(forKey: cacheKey) {
            thumbnail = cached
            return
        }
        do {
            let data = try await GoCore.shared.thumbnail(forCard: card.name, inCollectionAt: source.path)
            guard let image = PlatformImage(data: data) else { return }
            ThumbnailCache.shared.set(image, forKey: cacheKey)
            thumbnail = image
        } catch {
            // Leave the placeholder showing; one cell's failure shouldn't disrupt the grid.
        }
    }

    private func loadFrontDescription() async {
        guard let description = try? await GoCore.shared.metadata(forCard: card.name, inCollectionAt: source.path).front.description,
              !description.isEmpty else { return }
        frontDescription = description
    }
}
