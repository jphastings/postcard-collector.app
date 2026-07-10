import SwiftUI

/// Wraps the non-`Sendable` `CollectionReader` in an actor so this view's async tasks can't
/// race its single SQLite connection — mirrors `CollectionBox` in
/// `Extensions/QuickLookPreview/QuickLookPreviewRoot.swift`.
actor WatchCollectionStore {
    private let reader: CollectionReader

    init(path: String) throws {
        reader = try CollectionReader(path: path)
    }

    func title() throws -> String? { try reader.title() }
    func cardSummaries() throws -> [CardSummary] { try reader.cardSummaries() }
    func thumbnail(name: String) throws -> Data { try reader.thumbnail(name: name) }
    func imageData(name: String) throws -> Data { try reader.imageData(name: name) }
}

/// The watch's "one view" for an open collection: every card, one to a screen, snapping
/// vertically as you scroll — the Digital Crown drives this natively, since a Crown turn is
/// just another vertical scroll input to a paging `ScrollView`.
struct WatchPostcardScrollView: View {
    let id: String
    let fileURL: URL

    private enum Phase {
        case loading
        case failed(String)
        case loaded(WatchCollectionStore, [CardSummary])
    }

    @State private var phase: Phase = .loading
    @State private var title: String?
    /// Which card (by `CardSummary.name`), if any, currently has itself zoomed in
    /// (`WatchCardView` reports this back). Disables paging while set, so panning a zoomed
    /// card doesn't also flick the scroll view to the next one.
    @State private var zoomedCardID: String?

    var body: some View {
        content
            .navigationTitle(title ?? "")
            .task(id: fileURL) { await load() }
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
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(summaries) { summary in
                        WatchCardView(store: store, summary: summary, zoomedCardID: $zoomedCardID)
                            .containerRelativeFrame(.vertical)
                    }
                }
            }
            .scrollTargetBehavior(.paging)
            .scrollDisabled(zoomedCardID != nil)
        }
    }

    private func load() async {
        phase = .loading
        do {
            let store = try WatchCollectionStore(path: fileURL.path)
            async let loadedTitle = store.title()
            async let summaries = store.cardSummaries()
            let (resolvedTitle, resolvedSummaries) = try await (loadedTitle, summaries)
            title = resolvedTitle
            phase = .loaded(store, resolvedSummaries)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
