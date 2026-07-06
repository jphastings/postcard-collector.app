import SwiftUI

/// The grid behind the sidebar's synthetic "Single postcards" row (Feature 2): every bare
/// `.postcard.*` file the app knows about — imported or fully-downloaded from iCloud —
/// shown together, since none of them belongs to a collection worth its own sidebar row.
///
/// Unlike `CollectionGridView`, there's no Go-side FTS index spanning bare files (the Go
/// `Library`'s bare-file search is a simple substring scan, built for the cross-source
/// "Everywhere" scope) — searching here just filters the already-loaded summaries
/// client-side, which is simpler and just as correct for what's typically a handful of
/// loose cards.
struct SinglePostcardsGridView: View {
    let paths: [String]
    @Binding var selection: CardReference?
    var writableCollections: [WritableCollection] = []
    let cloudLibrary: CloudLibrary
    /// Called after a bare file is deleted (directly, or consumed by a successful move),
    /// so `LibraryModel` drops it from `sources` — a no-op if it was only ever an iCloud
    /// item, since `CloudLibrary`'s own metadata query notices the file is gone.
    var onFileConsumed: (String) -> Void = { _ in }

    /// `nil` until the first load completes.
    @State private var cards: [(path: String, summary: CardSummary)]?
    @State private var searchText = ""
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var viewMode = CollectionViewMode.grid
    /// Whether ANY loaded card has a coordinate — gates `CollectionModeSwitcher`. Computed
    /// from the full `cards` load, not `filteredCards`, so a search never disables it.
    @State private var hasAnyLocation = false

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 16)]

    private var filteredCards: [(path: String, summary: CardSummary)] {
        guard let cards else { return [] }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return cards }
        return cards.filter { _, summary in
            [summary.name, summary.senderName, summary.recipientName, summary.locationName]
                .compactMap { $0 }
                .contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Couldn't open postcards", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else if viewMode == .map {
                if cards != nil {
                    CollectionMapView(entries: mapEntries(from: filteredCards), selection: $selection)
                } else {
                    ProgressView()
                }
            } else if cards != nil {
                if filteredCards.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(filteredCards, id: \.path) { entry in
                                Button {
                                    selection = .bareFile(path: entry.path, summary: entry.summary)
                                } label: {
                                    BareGridCell(
                                        path: entry.path,
                                        card: entry.summary,
                                        writableCollections: writableCollections,
                                        onCopy: { card, target in Task { await copyCard(entry.path, card, to: target) } },
                                        onMove: { card, target in Task { await moveCard(entry.path, card, to: target) } },
                                        onDelete: { Task { await deleteFromDevice(entry.path) } }
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Single postcards")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CollectionModeSwitcher(mode: $viewMode, isEnabled: hasAnyLocation)
            }
        }
        // Search here is a client-side filter of the already-loaded `filteredCards` (see
        // its computed property above), not a separate fetch/scope like
        // `CollectionGridView`'s — so it keeps working in map mode for free, no extra
        // wiring needed.
        .searchable(text: $searchText, prompt: "Search single postcards")
        .task(id: paths) { await loadCards() }
        .alert(
            "Couldn't complete that action",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if searchText.isEmpty {
            ContentUnavailableView("No Single Postcards", systemImage: "photo.on.rectangle.angled")
        } else {
            ContentUnavailableView.search
        }
    }

    private func loadCards() async {
        loadError = nil
        var loaded: [(path: String, summary: CardSummary)] = []
        for path in paths {
            do {
                try await primeIfCloudBacked(path)
                loaded.append((path, try await GoCore.shared.summary(ofCardFileAt: path)))
            } catch {
                // One unreadable file shouldn't blank the whole grid; it just won't appear.
                continue
            }
        }
        cards = loaded
        hasAnyLocation = CollectionMapGating.isEnabled(for: loaded.map(\.summary))
    }

    private func mapEntries(from cards: [(path: String, summary: CardSummary)]) -> [MapCardEntry] {
        cards.compactMap { path, summary in
            guard summary.coordinate != nil else { return nil }
            return MapCardEntry(summary: summary, reference: .bareFile(path: path, summary: summary))
        }
    }

    // MARK: - Card actions (Feature 4)

    private func isCloudBacked(_ path: String) -> Bool {
        cloudLibrary.items.contains { $0.path == path }
    }

    private func primeIfCloudBacked(_ path: String) async throws {
        if isCloudBacked(path) {
            try await CloudLibrary.primeForGoCore(path: path)
        }
    }

    private func primeWriteIfCloudBacked(_ path: String) async throws {
        if isCloudBacked(path) {
            try await CloudLibrary.primeForGoCoreWrite(path: path)
        }
    }

    private func copyCard(_ path: String, _ card: CardSummary, to target: WritableCollection) async {
        do {
            let data = try await GoCore.shared.image(ofCardFileAt: path)
            try await primeWriteIfCloudBacked(target.path)
            try await GoCore.shared.addCard(filename: card.filename, data: data, toCollectionAt: target.path)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Copies first, and only deletes the original bare file once that copy has
    /// succeeded — the same never-lose-the-card ordering as `GoCore.moveCard`, just with a
    /// device-file delete standing in for `RemoveCardFromCollection` (there's no
    /// collection to remove *from* here).
    private func moveCard(_ path: String, _ card: CardSummary, to target: WritableCollection) async {
        do {
            let data = try await GoCore.shared.image(ofCardFileAt: path)
            try await primeWriteIfCloudBacked(target.path)
            try await GoCore.shared.addCard(filename: card.filename, data: data, toCollectionAt: target.path)
            try await deleteBareFile(path)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteFromDevice(_ path: String) async {
        do {
            try await deleteBareFile(path)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func deleteBareFile(_ path: String) async throws {
        await GoCore.shared.invalidateSource(at: path)
        try await CloudLibrary.deleteCoordinated(at: path)
        onFileConsumed(path)
        if case .bareFile(let selectedPath, _) = selection, selectedPath == path {
            selection = nil
        }
    }
}

/// Like `GridCell`, but for a bare `.postcard.*` file: there's no Go-generated thumbnail
/// for these (only collection cards get one), so the thumbnail is the front half of the
/// full decoded image — the same `ImageSplitter` split `CardDetailView` uses, just cached
/// and shown small instead of full-size.
private struct BareGridCell: View {
    let path: String
    let card: CardSummary
    var writableCollections: [WritableCollection] = []
    var onCopy: (CardSummary, WritableCollection) -> Void = { _, _ in }
    var onMove: (CardSummary, WritableCollection) -> Void = { _, _ in }
    var onDelete: () -> Void = {}

    @State private var thumbnail: PlatformImage?
    @State private var confirmingDeletion = false

    var body: some View {
        Group {
            if let thumbnail {
                Image(platformImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .aspectRatio(CGFloat(card.frontPxW) / CGFloat(max(card.frontPxH, 1)), contentMode: .fit)
        .contentShape(Rectangle())
        .accessibilityLabel(card.name)
        .accessibilityIdentifier(card.name)
        .task(id: path) { await loadThumbnail() }
        .contextMenu {
            Menu("Move to Collection…") {
                ForEach(writableCollections) { target in
                    Button(target.displayName) { onMove(card, target) }
                }
            }
            .disabled(writableCollections.isEmpty)
            Menu("Copy to Collection…") {
                ForEach(writableCollections) { target in
                    Button(target.displayName) { onCopy(card, target) }
                }
            }
            .disabled(writableCollections.isEmpty)
            Divider()
            Button("Delete from Device…", role: .destructive) { confirmingDeletion = true }
        }
        .confirmationDialog(
            "Delete “\(card.name)” from this device?",
            isPresented: $confirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
    }

    private func loadThumbnail() async {
        let cacheKey = "\(path)#thumbnail"
        if let cached = ThumbnailCache.shared.image(forKey: cacheKey) {
            thumbnail = cached
            return
        }
        do {
            let data = try await GoCore.shared.image(ofCardFileAt: path)
            let flip = card.flip
            let front = try await Task.detached(priority: .utility) {
                try ImageSplitter.split(data: data, flip: flip).front
            }.value
            let image = PlatformImage.from(cgImage: front)
            ThumbnailCache.shared.set(image, forKey: cacheKey)
            thumbnail = image
        } catch {
            // Leave the placeholder showing; one cell's failure shouldn't disrupt the grid.
        }
    }
}
