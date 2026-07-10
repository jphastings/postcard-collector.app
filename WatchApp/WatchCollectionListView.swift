import CoreGraphics
import ImageIO
import SwiftUI

/// Lists every collection the iPhone has advertised (`library.catalog`), pinned ones first.
/// Pinning (via the swipe action) asks the phone to send the collection's file so it's
/// cached on the watch and opens with no phone present; unpinning lets that cache lapse.
/// Every row navigates, downloaded or not — `WatchPostcardScrollView` itself handles
/// requesting an undownloaded collection from a reachable iPhone (Phase 2's live browsing)
/// or showing an unavailable state.
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
            thumbnail(for: info)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).lineLimit(1)
                Text(subtitle(for: info))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stateBadge(for: info)
        }
    }

    private func subtitle(for info: WatchCollectionInfo) -> String {
        if library.isDownloaded(info.id) {
            return "\(info.cardCount) cards"
        }
        if library.downloadProgress[info.id] != nil {
            return "Downloading…"
        }
        return library.isPhoneReachable ? "Tap to open" : "Needs iPhone nearby"
    }

    @ViewBuilder
    private func thumbnail(for info: WatchCollectionInfo) -> some View {
        if let data = info.coverThumbnail, let image = Self.decodeThumbnail(data) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private func stateBadge(for info: WatchCollectionInfo) -> some View {
        if library.isDownloaded(info.id) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if let progress = library.downloadProgress[info.id] {
            ProgressView(value: progress).frame(width: 24)
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

    private static func decodeThumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
