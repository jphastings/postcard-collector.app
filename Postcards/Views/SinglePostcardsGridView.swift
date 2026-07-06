import SwiftUI

/// The grid behind the sidebar's synthetic "Single postcards" row (Feature 2): every bare
/// `.postcard.*` file the app knows about — imported or fully-downloaded from iCloud —
/// shown together, since none of them belongs to a collection worth its own sidebar row.
///
/// Search goes through the Go core (`GoCore.searchCardFiles`, a `Library` scoped to just
/// these files) rather than a client-side filter over `CardSummary`, so "searchable text"
/// has one definition everywhere: descriptions and transcriptions match here exactly as
/// they do in a collection's FTS search.
struct SinglePostcardsGridView: View {
    let paths: [String]
    @Binding var selection: CardReference?
    var writableCollections: [WritableCollection] = []
    let cloudLibrary: CloudLibrary
    /// Called after a bare file is deleted (directly, or consumed by a successful move),
    /// so `LibraryModel` drops it from `sources` — a no-op if it was only ever an iCloud
    /// item, since `CloudLibrary`'s own metadata query notices the file is gone.
    var onFileConsumed: (String) -> Void = { _ in }
    /// See `CollectionGridView.onCreateCollection`.
    var onCreateCollection: ((String) async throws -> WritableCollection)?

    /// `nil` until the first load completes.
    @State private var cards: [MapCardEntry]?
    /// `nil` while no search is active; the Go-side hits otherwise.
    @State private var searchResults: [MapCardEntry]?
    @State private var searchText = ""
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var viewMode = CollectionViewMode.grid
    /// Whether ANY loaded card has a coordinate — gates `CollectionModeSwitcher`. Computed
    /// from the full `cards` load, never search results, so a search can't disable it.
    @State private var hasAnyLocation = false
    @State private var newCollectionPrompt: NewCollectionPrompt?
    @State private var newCollectionTitle = ""

    /// What both the grid and the map show: the search hits while a query is active, the
    /// full load otherwise — so map pins are filtered by search exactly like grid cells.
    private var displayedCards: [MapCardEntry]? {
        searchText.isEmpty ? cards : searchResults
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Couldn't open postcards", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if let displayedCards {
                if viewMode == .map {
                    CollectionMapView(entries: displayedCards.filter { $0.summary.coordinate != nil }, selection: $selection)
                } else if displayedCards.isEmpty {
                    emptyState
                } else {
                    MasonryGrid(items: displayedCards, aspectRatio: { Double($0.summary.frontPxW) / Double(max($0.summary.frontPxH, 1)) }) { entry in
                        Button {
                            selection = entry.reference
                        } label: {
                            BareGridCell(
                                path: entry.reference.sourcePath,
                                card: entry.summary,
                                writableCollections: writableCollections,
                                onCopy: { card, target in Task { await copyCard(entry.reference.sourcePath, card, to: target) } },
                                onMove: { card, target in Task { await moveCard(entry.reference.sourcePath, card, to: target) } },
                                onNewCollection: { card, action in promptForNewCollection(path: entry.reference.sourcePath, card: card, action: action) },
                                onDelete: { Task { await deleteFromDevice(entry.reference.sourcePath) } }
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Single postcards")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CollectionModeSwitcher(mode: $viewMode, isEnabled: hasAnyLocation)
            }
        }
        .searchable(text: $searchText, prompt: "Search single postcards")
        .task(id: paths) { await loadCards() }
        .task(id: searchText) { await search() }
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
        if searchText.isEmpty {
            ContentUnavailableView("No Single Postcards", systemImage: "photo.on.rectangle.angled")
        } else {
            ContentUnavailableView.search
        }
    }

    private func loadCards() async {
        loadError = nil
        var loaded: [MapCardEntry] = []
        for path in paths {
            do {
                try await primeIfCloudBacked(path)
                let summary = try await GoCore.shared.summary(ofCardFileAt: path)
                loaded.append(MapCardEntry(summary: summary, reference: .bareFile(path: path, summary: summary)))
            } catch {
                // One unreadable file shouldn't blank the whole grid; it just won't appear.
                continue
            }
        }
        cards = loaded
        hasAnyLocation = CollectionMapGating.isEnabled(for: loaded.map(\.summary))
    }

    private func search() async {
        guard !searchText.isEmpty else {
            searchResults = nil
            return
        }
        do {
            let hits = try await GoCore.shared.searchCardFiles(paths: paths, query: searchText)
            searchResults = MapCardEntry.entries(fromHits: hits)
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Card actions (Feature 4)

    private func isCloudBacked(_ path: String) -> Bool {
        cloudLibrary.items.contains { $0.path == path }
    }

    private func primeIfCloudBacked(_ path: String) async throws {
        if isCloudBacked(path) {
            try await CloudLibrary.primeForGoCore(path: path)
        }
    }

    private func primeWriteIfCloudBacked(_ path: String) async throws {
        if isCloudBacked(path) {
            try await CloudLibrary.primeForGoCoreWrite(path: path)
        }
    }

    private func copyCard(_ path: String, _ card: CardSummary, to target: WritableCollection) async {
        do {
            let data = try await GoCore.shared.image(ofCardFileAt: path)
            try await primeWriteIfCloudBacked(target.path)
            try await GoCore.shared.addCard(filename: card.filename, data: data, toCollectionAt: target.path)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Copies first, and only deletes the original bare file once that copy has
    /// succeeded — the same never-lose-the-card ordering as `GoCore.moveCard`, just with a
    /// device-file delete standing in for `RemoveCardFromCollection` (there's no
    /// collection to remove *from* here).
    private func moveCard(_ path: String, _ card: CardSummary, to target: WritableCollection) async {
        do {
            let data = try await GoCore.shared.image(ofCardFileAt: path)
            try await primeWriteIfCloudBacked(target.path)
            try await GoCore.shared.addCard(filename: card.filename, data: data, toCollectionAt: target.path)
            try await deleteBareFile(path)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteFromDevice(_ path: String) async {
        do {
            try await deleteBareFile(path)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteBareFile(_ path: String) async throws {
        await GoCore.shared.invalidateSource(at: path)
        try await CloudLibrary.deleteCoordinated(at: path)
        onFileConsumed(path)
        if case .bareFile(let selectedPath, _) = selection, selectedPath == path {
            selection = nil
        }
    }

    // MARK: - New collection…

    private func promptForNewCollection(path: String, card: CardSummary, action: CardTransferAction) {
        newCollectionTitle = ""
        newCollectionPrompt = NewCollectionPrompt(card: card, action: action, barePath: path)
    }

    private func createCollectionAndTransfer(_ prompt: NewCollectionPrompt, title: String) async {
        guard let onCreateCollection, let barePath = prompt.barePath else { return }
        do {
            let target = try await onCreateCollection(title)
            switch prompt.action {
            case .move: await moveCard(barePath, prompt.card, to: target)
            case .copy: await copyCard(barePath, prompt.card, to: target)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// Like `GridCell`, but for a bare `.postcard.*` file: there's no Go-generated thumbnail
/// for these (only collection cards get one), so the thumbnail is the front half of the
/// full decoded image — the same `ImageSplitter` split `CardDetailView` uses, just cached
/// and shown small instead of full-size.
private struct BareGridCell: View {
    let path: String
    let card: CardSummary
    var writableCollections: [WritableCollection] = []
    var onCopy: (CardSummary, WritableCollection) -> Void = { _, _ in }
    var onMove: (CardSummary, WritableCollection) -> Void = { _, _ in }
    var onNewCollection: (CardSummary, CardTransferAction) -> Void = { _, _ in }
    var onDelete: () -> Void = {}

    @State private var thumbnail: PlatformImage?
    @State private var confirmingDeletion = false

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
        .accessibilityLabel(card.name)
        .accessibilityIdentifier(card.name)
        .task(id: path) { await loadThumbnail() }
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
            Button("Delete from Device…", role: .destructive) { confirmingDeletion = true }
        }
        .confirmationDialog(
            "Delete “\(card.name)” from this device?",
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func loadThumbnail() async {
        let cacheKey = "\(path)#thumbnail"
        if let cached = ThumbnailCache.shared.image(forKey: cacheKey) {
            thumbnail = cached
            return
        }
        do {
            let data = try await GoCore.shared.image(ofCardFileAt: path)
            let flip = card.flip
            let front = try await Task.detached(priority: .utility) {
                try ImageSplitter.split(data: data, flip: flip).front
            }.value
            let image = PlatformImage.from(cgImage: front)
            ThumbnailCache.shared.set(image, forKey: cacheKey)
            thumbnail = image
        } catch {
            // Leave the placeholder showing; one cell's failure shouldn't disrupt the grid.
        }
    }
}
