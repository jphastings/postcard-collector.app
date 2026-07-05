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

/// The two scopes `CollectionGridView`'s search bar offers: the FTS index of just this
/// collection, or the cross-source Go `Library` fan-out over every currently-known
/// collection and bare card file (kept in sync by `LibraryView`).
enum GridSearchScope: String, CaseIterable, Hashable {
    case thisCollection = "This Collection"
    case everywhere = "Everywhere"
}

private struct SearchKey: Equatable {
    var text: String
    var scope: GridSearchScope
}

/// A grid of every card in a collection, searchable via the collection's FTS index or,
/// with the "Everywhere" scope, the cross-source Go `Library`. Cell aspect ratios come
/// from `CardSummary.frontPxW/H` alone, so the grid can lay itself out without decoding
/// any image data.
struct CollectionGridView: View {
    let source: LibrarySource
    @Binding var selection: CardReference?
    /// Resolves a `LibraryHit.source` path to a display name for grouping "Everywhere"
    /// results — sources can be bundled, imported, or iCloud, so `LibraryView` supplies
    /// this rather than `CollectionGridView` needing to know about every kind.
    var resolveSourceName: (String) -> String = { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    /// Every collection a card can be moved/copied into (Feature 4), for the grid cells'
    /// context menus — excludes this collection itself at the point of use.
    var writableCollections: [WritableCollection] = []
    let cloudLibrary: CloudLibrary

    /// `nil` until the first load/search completes; distinguishes "still loading" from a
    /// collection or search that has genuinely returned zero cards.
    @State private var cards: [CardSummary]?
    @State private var title: String?
    @State private var searchText = ""
    @State private var searchScope = GridSearchScope.thisCollection
    @State private var libraryHits: [LibraryHit] = []
    @State private var loadError: String?
    @State private var loadErrorTitle = "Couldn't open collection"
    @State private var actionError: String?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16)]

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    loadErrorTitle,
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if searchScope == .everywhere && !searchText.isEmpty {
                EverywhereResultsList(hits: libraryHits, selection: $selection, resolveSourceName: resolveSourceName)
            } else if let cards {
                if cards.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(cards) { card in
                                Button {
                                    selection = .inCollection(path: source.path, summary: card)
                                } label: {
                                    GridCell(
                                        source: source,
                                        card: card,
                                        writableCollections: writableCollections.filter { $0.path != source.path },
                                        onCopy: { card, target in Task { await copyCard(card, to: target) } },
                                        onMove: { card, target in Task { await moveCard(card, to: target) } },
                                        onRemove: { card in Task { await removeFromCollection(card) } }
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title ?? source.displayName)
        .searchable(text: $searchText, prompt: "Search this collection")
        .searchScopes($searchScope) {
            ForEach(GridSearchScope.allCases, id: \.self) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .task(id: source.id) { await loadCards() }
        .task(id: source.id) { await loadTitle() }
        .task(id: SearchKey(text: searchText, scope: searchScope)) { await search() }
        .alert(
            "Couldn't complete that action",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            ContentUnavailableView("No Postcards", systemImage: "photo.stack")
        } else {
            ContentUnavailableView.search
        }
    }

    private func loadCards() async {
        loadError = nil
        do {
            cards = try await GoCore.shared.cardSummaries(inCollectionAt: source.path)
        } catch {
            loadErrorTitle = "Couldn't open collection"
            loadError = error.localizedDescription
        }
    }

    private func loadTitle() async {
        if let fetched = try? await GoCore.shared.title(ofCollectionAt: source.path), !fetched.isEmpty {
            title = fetched
        }
    }

    private func search() async {
        guard !searchText.isEmpty else {
            libraryHits = []
            await loadCards()
            return
        }
        loadError = nil
        switch searchScope {
        case .thisCollection:
            do {
                cards = try await GoCore.shared.search(inCollectionAt: source.path, query: searchText).map(\.card)
            } catch {
                loadErrorTitle = "Search failed"
                loadError = error.localizedDescription
            }
        case .everywhere:
            do {
                libraryHits = try await GoCore.shared.searchLibrary(query: searchText)
            } catch {
                loadErrorTitle = "Search failed"
                loadError = error.localizedDescription
            }
        }
    }

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
}

/// "Everywhere" search results, grouped by source in the same order the Go `Library`
/// returned them (collection hits ranked within each collection, then bare-file hits).
private struct EverywhereResultsList: View {
    let hits: [LibraryHit]
    @Binding var selection: CardReference?
    let resolveSourceName: (String) -> String

    private var groupedBySource: [(source: String, hits: [LibraryHit])] {
        var order: [String] = []
        var bySource: [String: [LibraryHit]] = [:]
        for hit in hits {
            if bySource[hit.source] == nil { order.append(hit.source) }
            bySource[hit.source, default: []].append(hit)
        }
        return order.map { ($0, bySource[$0] ?? []) }
    }

    var body: some View {
        if hits.isEmpty {
            ContentUnavailableView.search
        } else {
            List {
                ForEach(groupedBySource, id: \.source) { group in
                    Section(resolveSourceName(group.source)) {
                        ForEach(group.hits) { hit in
                            Button {
                                selection = CardReference(hit: hit)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(hit.card.name).font(.headline)
                                    Text(hit.snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
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
    var writableCollections: [WritableCollection] = []
    var onCopy: (CardSummary, WritableCollection) -> Void = { _, _ in }
    var onMove: (CardSummary, WritableCollection) -> Void = { _, _ in }
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
        .accessibilityLabel(frontDescription ?? card.name)
        // Stable machine-facing handle for UI tests; the label above stays human-readable.
        .accessibilityIdentifier(card.name)
        .task(id: card.id) { await loadThumbnail() }
        .task(id: card.id) { await loadFrontDescription() }
        .contextMenu {
            Menu("Move to Collection…") {
                ForEach(writableCollections) { target in
                    Button(target.displayName) { onMove(card, target) }
                }
            }
            .disabled(writableCollections.isEmpty)
            Menu("Copy to Collection…") {
                ForEach(writableCollections) { target in
                    Button(target.displayName) { onCopy(card, target) }
                }
            }
            .disabled(writableCollections.isEmpty)
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
