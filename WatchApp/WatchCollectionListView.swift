import SwiftUI

/// Lists every collection the iPhone has advertised (`library.catalog`): the ones already on
/// the watch — or pinned to be kept there — first, then the ones only on the iPhone (see
/// `WatchCollectionSections`). Pinning (via the swipe action) keeps a collection downloaded,
/// zoom tier and all, so it opens with no phone present; unpinning lets that cache lapse
/// rather than deleting it. A separate "Remove Download" swipe action, shown once a collection
/// has any download, deletes its cache outright (unpinning it first if needed).
///
/// Every row opens its collection straight away: `WatchPostcardScrollView` asks the phone for
/// whatever's missing and shows each postcard the moment it arrives, rather than making the
/// person wait here for a download to finish.
struct WatchCollectionListView: View {
    let library: WatchLibrary

    var body: some View {
        let sections = WatchCollectionSections(
            catalog: library.catalog,
            pinned: library.pinnedIDs,
            isOnWatch: { library.isPresent($0) }
        )
        List {
            if !sections.onWatch.isEmpty {
                Section("Downloaded") {
                    ForEach(sections.onWatch) { CollectionRow(library: library, info: $0) }
                }
            }
            if !sections.onPhone.isEmpty {
                Section("On iPhone") {
                    ForEach(sections.onPhone) { CollectionRow(library: library, info: $0) }
                }
            }
        }
        .navigationTitle("Postcards")
        .navigationDestination(for: String.self) { id in
            WatchPostcardScrollView(library: library, id: id)
        }
        .overlay {
            if library.catalog.isEmpty {
                emptyOverlay
            }
        }
    }

    /// Before any catalog has arrived, the iPhone app has never been heard from — most likely
    /// never opened since it was installed — so this invites the person to open it (the watch
    /// also nudges it awake itself when the phone is in range). Once one has, an empty catalog
    /// really does mean no collections.
    @ViewBuilder
    private var emptyOverlay: some View {
        if library.hasReceivedCatalog {
            ContentUnavailableView(
                "No Collections",
                systemImage: "square.stack",
                description: Text("Add a collection to the Postcards folder in iCloud Drive on your iPhone.")
            )
        } else {
            ContentUnavailableView(
                "Open Postcards on iPhone",
                systemImage: "iphone",
                description: Text("Open the Postcards app on your iPhone while this app is open, and your collections will appear here.")
            )
        }
    }
}

/// Where a collection's download stands, as a list row shows it.
private enum CollectionDownloadStatus: Equatable {
    /// Only on the iPhone, which is in range: opening it downloads it.
    case notDownloaded
    /// Only on the iPhone, which isn't in range.
    case needsPhone
    /// Asked for; waiting on the phone's first reply.
    case waiting
    /// Arriving: how many cards' images have landed, of how many.
    case downloading(received: Int, expected: Int)
    /// Every card's images have landed.
    case downloaded(Int)

    /// How much has arrived, while downloading.
    var fraction: Double {
        guard case .downloading(let received, let expected) = self, expected > 0 else { return 0 }
        return Double(received) / Double(expected)
    }
}

/// One collection's row: a link that opens the collection, with its download status.
private struct CollectionRow: View {
    let library: WatchLibrary
    let info: WatchCollectionInfo

    var body: some View {
        let rowStatus = status
        NavigationLink(value: info.id) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.title).lineLimit(1)
                    Text(subtitle(for: rowStatus))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if library.isPinned(info.id) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                CollectionStatusBadge(status: rowStatus)
            }
        }
        // Full swipe would fire the edge-most action — the destructive Remove Download,
        // whose undo is a minutes-long Bluetooth re-stream — so it always takes a tap.
        .swipeActions(allowsFullSwipe: false) {
            if library.isPresent(info.id) {
                removeDownloadButton
            }
            pinButton
        }
    }

    private var status: CollectionDownloadStatus {
        if let expected = library.expectedCount(for: info.id) {
            let received = library.receivedCount(for: info.id)
            return received >= expected ? .downloaded(expected) : .downloading(received: received, expected: expected)
        }
        if library.isAwaitingManifest(info.id) {
            return .waiting
        }
        return library.isPhoneReachable ? .notDownloaded : .needsPhone
    }

    private func subtitle(for status: CollectionDownloadStatus) -> String {
        switch status {
        case .downloaded(let count):
            return Self.cardCount(count)
        case .downloading(let received, let expected):
            return "\(received) of \(Self.cardCount(expected))"
        case .waiting:
            return "Downloading…"
        case .notDownloaded:
            return info.cardCount > 0 ? Self.cardCount(info.cardCount) : "On iPhone"
        case .needsPhone:
            return "Needs iPhone nearby"
        }
    }

    private static func cardCount(_ count: Int) -> String {
        count == 1 ? "1 card" : "\(count) cards"
    }

    /// Toggles whether the collection is exempt from background eviction — "Unpin" doesn't
    /// delete anything itself, it just lets the cache lapse; use `removeDownloadButton` to
    /// delete outright.
    private var pinButton: some View {
        let isPinned = library.isPinned(info.id)
        return Button {
            library.setPinned(!isPinned, id: info.id)
        } label: {
            Label(isPinned ? "Unpin" : "Keep Downloaded", systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
        }
        .tint(isPinned ? .gray : .accentColor)
    }

    /// Deletes the downloaded collection outright (unpinning it first if needed), rather than
    /// just making it eligible for eviction. Only shown once something's actually downloaded.
    private var removeDownloadButton: some View {
        Button(role: .destructive) {
            library.removeDownload(id: info.id)
        } label: {
            Label("Remove Download", systemImage: "trash")
        }
    }
}

/// A row's trailing status glyph. Every state draws inside the same fixed square, centred —
/// progress as a ring the size of the icons, rather than a system spinner or bar with its own
/// intrinsic size and padding — so the glyphs line up down the right-hand edge whatever state
/// each row is in.
private struct CollectionStatusBadge: View {
    let status: CollectionDownloadStatus

    private static let side: CGFloat = 20

    var body: some View {
        glyph
            .frame(width: Self.side, height: Self.side)
    }

    @ViewBuilder
    private var glyph: some View {
        switch status {
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        case .downloading:
            ProgressRing(fraction: status.fraction)
                .accessibilityLabel("Downloading")
                .accessibilityValue(Text(status.fraction, format: .percent.precision(.fractionLength(0))))
        case .waiting:
            SpinningRing()
                .accessibilityLabel("Downloading")
        case .notDownloaded:
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not downloaded")
        case .needsPhone:
            Image(systemName: "iphone.slash")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Needs iPhone nearby")
        }
    }
}

/// A thin circular track, filled clockwise from the top to `fraction`.
private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0.03), 1))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
    }
}

/// The same track with a quarter arc sweeping round it, for a download that's been asked for
/// but hasn't reported its size yet. Driven by the timeline rather than a repeating
/// animation, which list rows can restart or drop as they re-render.
private struct SpinningRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(turns * 360))
            }
            .padding(1.5)
        }
    }
}
