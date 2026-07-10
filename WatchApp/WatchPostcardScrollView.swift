import SwiftUI

/// The watch's "one view" for an open collection: every card, one to a screen, snapping
/// vertically as you scroll — the Digital Crown drives this natively, since a Crown turn is
/// just another vertical scroll input to a paging `ScrollView`.
///
/// Progressive streaming means the manifest (every card's slot) typically lands well before
/// every card's image does, so this view renders a slot per `WatchCardMeta` the moment
/// `library.manifest(for: id)` is non-nil — each `WatchCardView` independently shows a
/// placeholder until its own blob arrives — with a small "N of M" overlay while the stream is
/// still filling in. If the manifest itself hasn't landed yet, this asks `library` to fetch it
/// from a reachable iPhone and waits, reacting to `library.manifests` the moment it lands and
/// to `library.isPhoneReachable` if the phone comes back within range mid-wait.
struct WatchPostcardScrollView: View {
    let library: WatchLibrary
    let id: String

    private enum Phase {
        /// Checking the local cache / waiting on the initial load — distinct from
        /// `.downloading` so we don't flash a "Downloading from iPhone…" message for a
        /// collection whose manifest turns out to already be cached.
        case loading
        case downloading
        case unavailable
        case loaded
    }

    /// How long to wait for a requested manifest before giving up and showing a failure state,
    /// rather than spinning forever if the phone stops responding mid-transfer.
    private static let downloadTimeout: Duration = .seconds(20)

    @State private var phase: Phase = .loading
    @State private var timedOut = false
    /// Which card (by `WatchCardMeta.name`), if any, currently has itself zoomed in
    /// (`WatchCardView` reports this back). Disables paging while set, so panning a zoomed
    /// card doesn't also flick the scroll view to the next one.
    @State private var zoomedCardID: String?
    /// Bumped every time a download is (re)requested, so a timeout task from an earlier
    /// attempt (e.g. before a reachability flap) recognises it's stale and no-ops.
    @State private var downloadAttempt = 0

    private var manifest: [WatchCardMeta]? { library.manifest(for: id) }
    private var title: String? { library.catalog.first { $0.id == id }?.title }

    var body: some View {
        content
            .navigationTitle(title ?? "")
            .task(id: id) { beginLoading() }
            .onChange(of: library.manifests) { _, _ in beginLoading() }
            .onChange(of: library.isPhoneReachable) { _, reachable in
                guard reachable else { return }
                beginLoading()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .downloading:
            if timedOut {
                ContentUnavailableView(
                    "Can't Open Collection",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Timed out waiting for the collection to arrive from iPhone.")
                )
            } else {
                ProgressView("Downloading from iPhone…")
            }
        case .unavailable:
            ContentUnavailableView(
                "iPhone Not Reachable",
                systemImage: "iphone.slash",
                description: Text("Bring your iPhone closer, or pin this collection to keep it on your Watch.")
            )
        case .loaded:
            if let manifest {
                loadedScroll(manifest)
            } else {
                ProgressView()
            }
        }
    }

    private func loadedScroll(_ manifest: [WatchCardMeta]) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(manifest) { meta in
                    WatchCardView(library: library, collectionID: id, meta: meta, zoomedCardID: $zoomedCardID)
                        .containerRelativeFrame(.vertical)
                }
            }
        }
        .scrollTargetBehavior(.paging)
        .scrollDisabled(zoomedCardID != nil)
        .overlay(alignment: .top) {
            let received = library.receivedCount(for: id)
            if received < manifest.count {
                Text("\(received) of \(manifest.count)")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 4)
            }
        }
    }

    /// Loads from the cache if the manifest is already there; otherwise requests it (if
    /// reachable) or shows the unavailable state. Safe to call repeatedly — e.g. from both the
    /// initial `.task` and every subsequent `manifests`/`isPhoneReachable` change — since it's
    /// a no-op once loaded.
    private func beginLoading() {
        if library.isPresent(id) {
            phase = .loaded
            return
        }
        guard library.isPhoneReachable else {
            phase = .unavailable
            return
        }
        phase = .downloading
        timedOut = false
        library.requestDownloadIfNeeded(id: id)
        downloadAttempt += 1
        let attempt = downloadAttempt
        Task { await watchForTimeout(attempt: attempt) }
    }

    private func watchForTimeout(attempt: Int) async {
        try? await Task.sleep(for: Self.downloadTimeout)
        guard !Task.isCancelled, attempt == downloadAttempt, case .downloading = phase else { return }
        timedOut = true
    }
}
