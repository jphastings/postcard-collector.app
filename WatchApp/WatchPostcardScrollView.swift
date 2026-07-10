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
///
/// Phase 2: not every collection this view is pushed for is downloaded yet. If it isn't, this
/// asks `library` to fetch it from a reachable iPhone and waits, reacting to
/// `library.downloadedIDs` the moment the file lands and to `library.isPhoneReachable` if the
/// phone comes back within range mid-wait.
struct WatchPostcardScrollView: View {
    let library: WatchLibrary
    let id: String

    private enum Phase {
        /// Checking the local cache / waiting on the initial load — distinct from
        /// `.downloading` so we don't flash a "Downloading from iPhone…" message for a
        /// collection that turns out to already be cached.
        case loading
        case downloading
        case unavailable
        case failed(String)
        case loaded(WatchCollectionStore, [CardSummary])
    }

    /// How long to wait for a requested file before giving up and showing a failure state,
    /// rather than spinning forever if the phone stops responding mid-transfer.
    private static let downloadTimeout: Duration = .seconds(20)

    @State private var phase: Phase = .loading
    @State private var title: String?
    /// Which card (by `CardSummary.name`), if any, currently has itself zoomed in
    /// (`WatchCardView` reports this back). Disables paging while set, so panning a zoomed
    /// card doesn't also flick the scroll view to the next one.
    @State private var zoomedCardID: String?
    /// Bumped every time a download is (re)requested, so a timeout task from an earlier
    /// attempt (e.g. before a reachability flap) recognises it's stale and no-ops.
    @State private var downloadAttempt = 0

    var body: some View {
        content
            .navigationTitle(title ?? "")
            .task(id: id) { await beginLoading() }
            .onChange(of: library.downloadedIDs) { _, _ in
                Task { await beginLoading() }
            }
            .onChange(of: library.isPhoneReachable) { _, reachable in
                guard reachable else { return }
                Task { await beginLoading() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .downloading:
            ProgressView("Downloading from iPhone…")
        case .unavailable:
            ContentUnavailableView(
                "iPhone Not Reachable",
                systemImage: "iphone.slash",
                description: Text("Bring your iPhone closer, or pin this collection to keep it on your Watch.")
            )
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

    /// Loads from the cache if the file is already there; otherwise requests it (if reachable)
    /// or shows the unavailable state. Safe to call repeatedly — e.g. from both the initial
    /// `.task` and every subsequent `downloadedIDs`/`isPhoneReachable` change — since it's a
    /// no-op once loaded.
    private func beginLoading() async {
        if case .loaded = phase { return }
        if let url = library.localFileURL(for: id) {
            await load(from: url)
            return
        }
        guard library.isPhoneReachable else {
            phase = .unavailable
            return
        }
        phase = .downloading
        library.requestDownloadIfNeeded(id: id)
        downloadAttempt += 1
        let attempt = downloadAttempt
        Task { await watchForTimeout(attempt: attempt) }
    }

    private func watchForTimeout(attempt: Int) async {
        try? await Task.sleep(for: Self.downloadTimeout)
        guard !Task.isCancelled, attempt == downloadAttempt, case .downloading = phase else { return }
        phase = .failed("Timed out waiting for the collection to arrive from iPhone.")
    }

    private func load(from url: URL) async {
        do {
            let store = try WatchCollectionStore(path: url.path)
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
