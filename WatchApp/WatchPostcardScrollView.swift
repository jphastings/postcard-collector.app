import SwiftUI

/// The watch's "one view" for an open collection: every card, one to a screen, snapping
/// vertically as you scroll — the Digital Crown drives this natively, since a Crown turn is
/// just another vertical scroll input to a paging `ScrollView`. Swiping up or down pages too,
/// but through each card's own drag gesture (see `WatchCardView`), which keeps the scroll
/// view's touch scrolling from starting: the card asks, and this moves `scrolledCardID`. A
/// swipe from the top of a card hides or brings back the controls (`isFullScreen`) instead.
///
/// Progressive streaming means the manifest (every card's slot) typically lands well before
/// every card's faces do, so this view renders a slot per `WatchCardMeta` the moment
/// `library.manifest(for: id)` is non-nil — each `WatchCardView` independently shows a
/// placeholder until its own screen-tier faces arrive, the first within a second or two. If
/// the manifest itself hasn't landed yet, this asks `library` to fetch it from a reachable
/// iPhone and waits, reacting to the collection appearing in `library` the moment it lands
/// and to `library.isPhoneReachable` if the phone comes back within range mid-wait. While
/// open, a partly-downloaded collection that stops arriving is asked for again.
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
    /// How many times a stalled download is silently re-requested before showing the failure
    /// state — the phone may just be slow to notice the request (e.g. it woke from a
    /// background launch and is still spinning up `CloudLibrary`), not gone for good.
    private static let maxDownloadStrikes = 3
    /// How long a partly-downloaded collection can go with nothing new arriving before it's
    /// asked for again — the phone app may have been suspended mid-stream.
    private static let stallInterval: TimeInterval = 30

    @State private var phase: Phase = .loading
    @State private var timedOut = false
    /// Which card (by `WatchCardMeta.name`), if any, currently has itself zoomed in
    /// (`WatchCardView` reports this back). Disables paging while set, so panning a zoomed
    /// card doesn't also flick the scroll view to the next one.
    @State private var zoomedCardID: String?
    /// The card the scroll view is showing (by `WatchCardMeta.id`), kept up to date as the
    /// crown scrolls it, and set to page it when a card is swiped. `nil` until it first moves.
    @State private var scrolledCardID: String?
    /// Whether the collection's controls — its back button and title — are hidden, giving the
    /// cards the whole screen. A swipe up from the top of a card hides them, and a swipe down
    /// from the top of the screen brings them back (see `WatchCardView`).
    @State private var isFullScreen = false
    /// Bumped every time a download is (re)requested, so a timeout task from an earlier
    /// attempt (e.g. before a reachability flap) recognises it's stale and no-ops.
    @State private var downloadAttempt = 0
    /// Consecutive timeouts within the current download attempt, reset whenever `beginLoading`
    /// runs afresh (a new request, or the phase actually leaving `.downloading`).
    @State private var timeoutStrikes = 0
    /// The card whose info page is showing, if any.
    @State private var infoCard: WatchCardMeta?

    private var manifest: [WatchCardMeta]? { library.manifest(for: id) }
    private var title: String? { library.catalog.first { $0.id == id }?.title }

    var body: some View {
        content
            .navigationTitle(title ?? "")
            .task(id: id) { beginLoading() }
            .task(id: id) { await watchForStalls() }
            .onChange(of: library.isPresent(id)) { _, _ in beginLoading() }
            .onChange(of: library.isPhoneReachable) { _, reachable in
                guard reachable else { return }
                beginLoading()
            }
            .sheet(item: $infoCard) { meta in
                WatchCardInfoView(library: library, collectionID: id, meta: meta)
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
                    description: Text("Timed out waiting for the collection to arrive from iPhone. It may be out of reach — try again once it's nearby.")
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
        // Read within the safe area, for the controls' height: the scroll view ignores it, so
        // every card's slot is the whole screen whether or not the controls are showing, and
        // each card keeps clear of them itself. Hiding them then only re-centres the card in
        // its slot — resizing every slot instead would move every card's place in the scroll,
        // and with it which card is showing.
        GeometryReader { screen in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(manifest) { meta in
                        WatchCardView(
                            library: library,
                            collectionID: id,
                            meta: meta,
                            zoomedCardID: $zoomedCardID,
                            isFullScreen: isFullScreen,
                            controlsHeight: screen.safeAreaInsets.top,
                            onShowInfo: { infoCard = meta },
                            onPage: { step in
                                if let target = WatchCardInteraction.pageTarget(from: meta.id, step: step, in: manifest.map(\.id)) {
                                    scrolledCardID = target
                                }
                            },
                            onFullScreen: { isFullScreen = $0 }
                        )
                        .containerRelativeFrame(.vertical)
                    }
                }
                .scrollTargetLayout()
            }
            // Both edges, so the slots run to the physical screen's: the bottom reclaims the
            // space that used to be spent peeking the next card, and the top runs under the
            // controls (the previous card scrolls up beneath them) or, in full screen, where
            // they were.
            .ignoresSafeArea(edges: .vertical)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $scrolledCardID)
            .scrollDisabled(zoomedCardID != nil)
        }
        .toolbar(isFullScreen ? .hidden : .automatic, for: .navigationBar)
    }

    /// Loads from the cache if the manifest is already there; otherwise requests it (if
    /// reachable) or shows the unavailable state. Safe to call repeatedly — e.g. from both the
    /// initial `.task` and every subsequent presence/reachability change — since the library
    /// drops a request that's already on its way.
    private func beginLoading() {
        // Any fresh call represents progress — either the collection is now present, or
        // something changed (a new request, a reachability flap) worth giving a full set of
        // retries again.
        timeoutStrikes = 0

        if library.isPresent(id) {
            phase = .loaded
            library.requestDownloadIfNeeded(id: id)
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

    /// Fires once per `downloadTimeout` while still `.downloading`. The phone may simply be
    /// slow to notice the request (e.g. it woke from a background launch and is still
    /// spinning up `CloudLibrary`), so the first couple of strikes just re-send the request
    /// and re-arm rather than failing permanently — only the last strike shows the failure.
    private func watchForTimeout(attempt: Int) async {
        try? await Task.sleep(for: Self.downloadTimeout)
        guard !Task.isCancelled, attempt == downloadAttempt, case .downloading = phase else { return }

        timeoutStrikes += 1
        guard timeoutStrikes >= Self.maxDownloadStrikes else {
            library.requestDownloadIfNeeded(id: id, force: true)
            await watchForTimeout(attempt: attempt)
            return
        }
        timedOut = true
    }

    /// While the collection is open, re-asks for it whenever it's incomplete and has gone
    /// `stallInterval` with nothing arriving. Ends when the view goes away.
    private func watchForStalls() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.stallInterval))
            guard !Task.isCancelled else { return }
            if library.isPresent(id), library.isPhoneReachable {
                library.requestDownloadIfStalled(id: id, interval: Self.stallInterval)
            }
        }
    }
}
