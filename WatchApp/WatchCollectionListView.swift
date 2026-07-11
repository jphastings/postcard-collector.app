import SwiftUI

/// Lists every collection the iPhone has advertised (`library.catalog`), pinned ones first.
/// Pinning (via the swipe action) asks the phone to stream the collection so it's cached on
/// the watch and opens with no phone present; unpinning lets that cache lapse.
///
/// A row only navigates once it's `library.isOpenable` — manifest landed and at least one
/// card's screen faces cached — so opening it always shows a real postcard immediately. Before
/// that, tapping the row starts (or resumes) the download instead of navigating; the row's own
/// state badge/subtitle is the feedback, and the row turns into a `NavigationLink` on its own
/// once the download catches up (no auto-navigation — the user taps again to enter).
struct WatchCollectionListView: View {
    let library: WatchLibrary

    private var pinned: [WatchCollectionInfo] {
        library.catalog
            .filter { library.isPinned($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var unpinned: [WatchCollectionInfo] {
        library.catalog
            .filter { !library.isPinned($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            if !pinned.isEmpty {
                Section("Kept Downloaded") {
                    ForEach(pinned) { CollectionRow(library: library, info: $0) }
                }
            }
            Section {
                ForEach(unpinned) { CollectionRow(library: library, info: $0) }
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

    private var emptyOverlay: some View {
        ContentUnavailableView(
            "No Collections",
            systemImage: "square.stack",
            description: Text("Open the Postcards app on your iPhone.")
        )
    }
}

/// One collection's row. Not openable yet → a plain `Button` that (re)requests the download and
/// remembers, locally, that it did — `requested` — so the badge/subtitle can flip to "Downloading…"
/// immediately on tap, before the manifest itself has even landed to give `library` anything to
/// report. Once `library.isOpenable` turns true the row becomes a `NavigationLink` instead, and
/// `requested` stops mattering.
private struct CollectionRow: View {
    let library: WatchLibrary
    let info: WatchCollectionInfo

    @State private var requested = false

    var body: some View {
        Group {
            if library.isOpenable(info.id) {
                NavigationLink(value: info.id) { label }
            } else {
                Button {
                    // `requestDownloadIfNeeded` no-ops when unreachable, so only claim
                    // "requested" when a request was actually sent — otherwise the badge
                    // could falsely read "Downloading…" once the phone comes back in range.
                    if library.isPhoneReachable {
                        requested = true
                    }
                    library.requestDownloadIfNeeded(id: info.id)
                } label: {
                    label
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions {
            pinButton
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if library.isPinned(info.id) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            stateBadge
        }
    }

    private var subtitle: String {
        guard let expected = library.expectedCount(for: info.id) else {
            guard library.isPhoneReachable else { return "Needs iPhone nearby" }
            return requested ? "Downloading…" : "Tap to download"
        }
        let received = library.receivedCount(for: info.id)
        if received >= expected {
            return "\(expected) cards"
        }
        return "\(received) of \(expected) cards"
    }

    @ViewBuilder
    private var stateBadge: some View {
        if let expected = library.expectedCount(for: info.id) {
            let received = library.receivedCount(for: info.id)
            if received >= expected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ProgressView(value: Double(received), total: Double(max(expected, 1))).frame(width: 24)
            }
        } else if requested, library.isPhoneReachable {
            ProgressView()
        } else {
            Image(systemName: "icloud").foregroundStyle(.secondary)
        }
    }

    private var pinButton: some View {
        let isPinned = library.isPinned(info.id)
        return Button {
            library.setPinned(!isPinned, id: info.id)
        } label: {
            Label(isPinned ? "Remove" : "Keep Downloaded", systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
        }
        .tint(isPinned ? .red : .accentColor)
    }
}
