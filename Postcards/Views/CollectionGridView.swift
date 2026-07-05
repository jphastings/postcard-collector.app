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

    @State private var cards: [CardSummary] = []
    @State private var searchText = ""
    @State private var searchScope = GridSearchScope.thisCollection
    @State private var libraryHits: [LibraryHit] = []
    @State private var loadError: String?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16)]

    var body: some View {
        Group {
            if searchScope == .everywhere && !searchText.isEmpty {
                EverywhereResultsList(hits: libraryHits, selection: $selection, resolveSourceName: resolveSourceName)
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn't open collection",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if cards.isEmpty {
                ProgressView()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(cards) { card in
                            Button {
                                selection = .inCollection(path: source.path, summary: card)
                            } label: {
                                GridCell(source: source, card: card)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(source.displayName)
        .searchable(text: $searchText, prompt: "Search this collection")
        .searchScopes($searchScope) {
            ForEach(GridSearchScope.allCases, id: \.self) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .task(id: source.id) { await loadCards() }
        .task(id: SearchKey(text: searchText, scope: searchScope)) { await search() }
    }

    private func loadCards() async {
        loadError = nil
        do {
            cards = try await GoCore.shared.cardSummaries(inCollectionAt: source.path)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func search() async {
        guard !searchText.isEmpty else {
            libraryHits = []
            await loadCards()
            return
        }
        switch searchScope {
        case .thisCollection:
            do {
                cards = try await GoCore.shared.search(inCollectionAt: source.path, query: searchText).map(\.card)
            } catch {
                loadError = error.localizedDescription
            }
        case .everywhere:
            do {
                libraryHits = try await GoCore.shared.searchLibrary(query: searchText)
            } catch {
                loadError = error.localizedDescription
            }
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

private struct GridCell: View {
    let source: LibrarySource
    let card: CardSummary

    @State private var thumbnail: PlatformImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let thumbnail {
                    Image(platformImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(CGFloat(card.frontPxW) / CGFloat(max(card.frontPxH, 1)), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(card.name)
                .font(.headline)
                .lineLimit(1)

            if let sender = card.senderName, let recipient = card.recipientName {
                Text("\(sender) → \(recipient)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: card.id) { await loadThumbnail() }
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
}
