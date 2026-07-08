import SwiftUI

/// Wraps the non-`Sendable` `CollectionReader` in an actor so this view's async tasks can't
/// race its single SQLite connection — mirrors `CollectionBox` in
/// `Extensions/QuickLookPreview/QuickLookPreviewRoot.swift`.
actor WatchCollectionStore {
    private let reader: CollectionReader

    init(path: String) throws {
        reader = try CollectionReader(path: path)
    }

    func cardSummaries() throws -> [CardSummary] { try reader.cardSummaries() }
    func thumbnail(name: String) throws -> Data { try reader.thumbnail(name: name) }
    func imageData(name: String) throws -> Data { try reader.imageData(name: name) }
}

/// One long vertical list of every card in a collection, thumbnail-first (see
/// `WatchCardRow`). Opened with a short coordinated read first (`primeForGoCore` — the name
/// is historical, it's Go-agnostic) so a concurrent iCloud sync can't be read mid-update.
struct WatchCollectionView: View {
    let item: CloudItem

    private enum Phase {
        case loading
        case failed(String)
        case loaded(WatchCollectionStore, [CardSummary])
    }

    @State private var phase: Phase = .loading

    var body: some View {
        content
            .navigationTitle(item.displayName)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView(
                "Can't Open Collection",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let store, let summaries):
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(summaries) { summary in
                        WatchCardRow(store: store, summary: summary)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func load() async {
        do {
            try await CloudLibrary.primeForGoCore(path: item.path)
            let store = try WatchCollectionStore(path: item.path)
            let summaries = try await store.cardSummaries()
            phase = .loaded(store, summaries)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
