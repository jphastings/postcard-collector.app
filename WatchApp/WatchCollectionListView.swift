import SwiftUI

/// Lists every collection the iPhone has advertised (`library.catalog`), pinned ones first.
/// Pinning (via the swipe action) asks the phone to stream the collection so it's cached on
/// the watch and opens with no phone present; unpinning lets that cache lapse. Every row
/// navigates, streamed or not — `WatchPostcardScrollView` itself handles requesting an
/// unstreamed collection from a reachable iPhone (live browsing) or showing an unavailable
/// state.
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
                    ForEach(pinned, content: row)
                }
            }
            Section {
                ForEach(unpinned, content: row)
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

    private func row(for info: WatchCollectionInfo) -> some View {
        NavigationLink(value: info.id) { rowLabel(info) }
            .swipeActions {
                pinButton(for: info)
            }
    }

    private func rowLabel(_ info: WatchCollectionInfo) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).lineLimit(1)
                Text(subtitle(for: info))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if library.isPinned(info.id) {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            stateBadge(for: info)
        }
    }

    private func subtitle(for info: WatchCollectionInfo) -> String {
        guard let expected = library.expectedCount(for: info.id) else {
            return library.isPhoneReachable ? "Tap to open" : "Needs iPhone nearby"
        }
        let received = library.receivedCount(for: info.id)
        if received >= expected {
            return "\(expected) cards"
        }
        return "\(received) of \(expected) cards"
    }

    @ViewBuilder
    private func stateBadge(for info: WatchCollectionInfo) -> some View {
        if let expected = library.expectedCount(for: info.id) {
            let received = library.receivedCount(for: info.id)
            if received >= expected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ProgressView(value: Double(received), total: Double(max(expected, 1))).frame(width: 24)
            }
        } else {
            Image(systemName: "icloud").foregroundStyle(.secondary)
        }
    }

    private func pinButton(for info: WatchCollectionInfo) -> some View {
        let isPinned = library.isPinned(info.id)
        return Button {
            library.setPinned(!isPinned, id: info.id)
        } label: {
            Label(isPinned ? "Remove" : "Keep Downloaded", systemImage: isPinned ? "pin.slash.fill" : "pin.fill")
        }
        .tint(isPinned ? .red : .accentColor)
    }
}
