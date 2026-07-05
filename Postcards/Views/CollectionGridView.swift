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

/// A grid of every card in a collection, searchable via the collection's FTS index.
/// Cell aspect ratios come from `CardSummary.frontPxW/H` alone, so the grid can lay
/// itself out without decoding any image data.
struct CollectionGridView: View {
    let source: LibrarySource
    @Binding var selection: CardReference?

    @State private var cards: [CardSummary] = []
    @State private var searchText = ""
    @State private var loadError: String?

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16)]

    var body: some View {
        Group {
            if let loadError {
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
        .task(id: source.id) { await loadCards() }
        .task(id: searchText) { await search() }
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
            await loadCards()
            return
        }
        do {
            cards = try await GoCore.shared.search(inCollectionAt: source.path, query: searchText).map(\.card)
        } catch {
            loadError = error.localizedDescription
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
