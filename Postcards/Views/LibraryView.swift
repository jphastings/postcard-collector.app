import SwiftUI

/// The app's root: a sidebar of collections (bundled fixtures are gone — see Feature 1;
/// nothing is bundled), a grid of the selected collection's cards, and the selected card's
/// detail. Bare `.postcard.*` files never get their own sidebar row (see Feature 2): they're
/// aggregated into one "Single postcards" row pinned at the bottom.
struct LibraryView: View {
    let library: LibraryModel
    let cloudLibrary: CloudLibrary

    @State private var selectedSource: LibrarySource?
    @State private var selectedCard: CardReference?
    @State private var isImporting = false

    // Sidebar row actions (Feature 3).
    @State private var renamingSource: LibrarySource?
    @State private var renameText = ""
    @State private var pendingDeletion: LibrarySource?
    /// Bumped per-path after a successful rename so `SourceRow`/`CloudItemRow` re-fetch the
    /// title instead of showing the stale cached one (their `.task(id:)` doesn't otherwise
    /// change just because the title changed underneath them).
    @State private var titleRefreshTokens: [String: Int] = [:]

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if hasAnySources {
                    sourceList
                } else {
                    emptyLibraryView
                }
                if cloudLibrary.containerState == .unavailable {
                    Text("Sign in to iCloud to sync collections")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .navigationTitle("Postcards")
            .toolbar {
                ToolbarItem {
                    Button("Add…", systemImage: "plus") { isImporting = true }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await library.importSources(from: urls) }
                case .failure(let error):
                    library.importError = error.localizedDescription
                }
            }
            .alert(
                "Couldn't open file",
                isPresented: Binding(
                    get: { library.importError != nil },
                    set: { if !$0 { library.importError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.importError ?? "")
            }
            .alert(
                "Rename Collection",
                isPresented: Binding(get: { renamingSource != nil }, set: { if !$0 { renamingSource = nil } })
            ) {
                TextField("Title", text: $renameText)
                Button("Save") {
                    if let source = renamingSource { Task { await renameCollection(source, to: renameText) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a new title for this collection.")
            }
            .confirmationDialog(
                pendingDeletion.map { "Delete “\($0.displayName)”?" } ?? "Delete?",
                isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let pendingDeletion { Task { await deleteCollection(pendingDeletion) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the file. This can't be undone.")
            }
        } content: {
            if !hasAnySources {
                emptyLibraryView
            } else if let selectedSource {
                switch selectedSource {
                case .collection:
                    CollectionGridView(
                        source: selectedSource,
                        selection: $selectedCard,
                        resolveSourceName: displayName(forSourcePath:),
                        writableCollections: writableCollections,
                        cloudLibrary: cloudLibrary
                    )
                case .cardFile(let path, _):
                    // No longer reachable via the sidebar (bare files live only inside
                    // "Single postcards" now), kept so the switch stays exhaustive and
                    // safe if a bare-file source is ever selected some other way.
                    SingleCardSourceView(path: path, selection: $selectedCard)
                case .singlePostcards:
                    SinglePostcardsGridView(
                        paths: singlePostcardPaths,
                        selection: $selectedCard,
                        writableCollections: writableCollections,
                        cloudLibrary: cloudLibrary,
                        onFileConsumed: { library.remove(path: $0) }
                    )
                }
            } else {
                ContentUnavailableView("Select a Collection", systemImage: "photo.stack.fill")
            }
        } detail: {
            if let selectedCard {
                CardDetailView(reference: selectedCard)
            } else {
                ContentUnavailableView("Select a Postcard", systemImage: "photo")
            }
        }
        // Finder/Files drops of .postcards / .postcard.* files anywhere on the window.
        .dropDestination(for: URL.self) { urls, _ in
            Task { await library.importSources(from: urls) }
            return true
        }
        // Double-click / "Open With" documents (see CFBundleDocumentTypes in project.yml).
        .onOpenURL { url in
            Task { await library.importSources(from: [url]) }
        }
        .task { await runAutomationHookIfRequested() }
        // A cloud-backed source is only reachable once it's tagged as `.current`, but the
        // path underneath it can still be mid-write from a concurrent iCloud sync; prime it
        // with a short coordinated read before CollectionGridView/SingleCardSourceView hand
        // the path to the Go core.
        .onChange(of: selectedSource) { _, newSource in
            guard let newSource, cloudLibrary.items.contains(where: { $0.path == newSource.path }) else { return }
            Task {
                do {
                    try await CloudLibrary.primeForGoCore(path: newSource.path)
                } catch {
                    library.importError = error.localizedDescription
                }
            }
        }
        // Keeps the "Everywhere" search fan-out current as sources are imported, removed,
        // or synced in from iCloud.
        .onChange(of: library.sources, initial: true) { _, _ in
            Task { await syncEverywhereSearchSources() }
        }
        .onChange(of: cloudLibrary.items, initial: true) { _, _ in
            Task { await syncEverywhereSearchSources() }
        }
    }

    // MARK: - Sidebar

    private var sourceList: some View {
        List(selection: $selectedSource) {
            Section("Library") {
                ForEach(library.sources.filter(\.isCollection)) { source in
                    SourceRow(source: source, refreshToken: titleRefreshTokens[source.path, default: 0])
                        .tag(source)
                        .contextMenu { importedCollectionMenu(for: source) }
                }
            }
            if cloudLibrary.containerState == .available {
                Section("iCloud") {
                    // Fully-downloaded bare files move into "Single postcards" below;
                    // not-yet-downloaded ones stay here (aggregating them before they
                    // exist locally would just mean showing progress rows in two places).
                    ForEach(cloudLibrary.items.filter { $0.isCollection || $0.downloadState != .current }) { item in
                        if item.downloadState == .current {
                            CloudItemRow(item: item, refreshToken: titleRefreshTokens[item.path, default: 0])
                                .tag(item.librarySource)
                                .contextMenu { cloudCollectionMenu(for: item) }
                        } else {
                            CloudItemRow(item: item, refreshToken: 0)
                        }
                    }
                }
            }
            if hasAnyBareCard {
                Section {
                    Label("Single postcards", systemImage: "photo.on.rectangle.angled")
                        .accessibilityIdentifier("Single postcards")
                        .tag(LibrarySource.singlePostcards)
                }
            }
        }
    }

    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("No Collections", systemImage: "tray")
        } description: {
            Text("Open a .postcards file, or drop postcards into iCloud Drive/Postcards.")
        } actions: {
            Button("Open…") { isImporting = true }
        }
    }

    private var hasAnySources: Bool {
        !library.sources.isEmpty || !cloudLibrary.items.isEmpty
    }

    /// Every bare `.postcard.*` file the app currently knows about, imported or synced —
    /// only fully-downloaded iCloud ones (see `sourceList`'s comment on the iCloud section).
    private var singlePostcardPaths: [String] {
        var paths = library.sources.compactMap { source -> String? in
            if case .cardFile(let path, _) = source { return path }
            return nil
        }
        paths += cloudLibrary.items
            .filter { !$0.isCollection && $0.downloadState == .current }
            .map(\.path)
        return paths
    }

    private var hasAnyBareCard: Bool { !singlePostcardPaths.isEmpty }

    /// Every collection the app currently knows about — imported plus fully-downloaded
    /// iCloud ones — for the grid cells' "Move to Collection…"/"Copy to Collection…" menus.
    private var writableCollections: [WritableCollection] {
        var collections = library.sources.compactMap { source -> WritableCollection? in
            guard case .collection(let path, let name) = source else { return nil }
            return WritableCollection(path: path, displayName: name)
        }
        collections += cloudLibrary.items
            .filter { $0.isCollection && $0.downloadState == .current }
            .map { WritableCollection(path: $0.path, displayName: $0.displayName) }
        return collections
    }

    // MARK: - Sidebar row actions (Feature 3)

    @ViewBuilder
    private func importedCollectionMenu(for source: LibrarySource) -> some View {
        Button("Rename…") {
            renameText = source.displayName
            renamingSource = source
        }
        // "Remove from Library" reads as a non-destructive "just forget it", but an
        // imported collection's only copy lives in the app's own container — there's
        // nothing else to "remove" it from, so this does delete that copy. "Delete…"
        // below reaches the same end state, just behind an explicit confirmation.
        Button("Remove from Library") {
            Task { await removeFromLibrary(source) }
        }
        Divider()
        Button("Delete…", role: .destructive) {
            pendingDeletion = source
        }
    }

    /// Only ever called for a fully-downloaded, `isCollection` item — see the filter in
    /// `sourceList`'s iCloud section, which excludes non-collection items once they're
    /// current (they move to "Single postcards" instead).
    @ViewBuilder
    private func cloudCollectionMenu(for item: CloudItem) -> some View {
        Button("Rename…") {
            renameText = item.displayName
            renamingSource = item.librarySource
        }
        Divider()
        // No "Remove from Library" here: iCloud collections come from the folder scan,
        // so "removing" one from the sidebar without deleting the file would just have it
        // reappear on the next `NSMetadataQuery` update. Only a real deletion is meaningful.
        Button("Delete…", role: .destructive) {
            pendingDeletion = item.librarySource
        }
    }

    private func renameCollection(_ source: LibrarySource, to newTitle: String) async {
        do {
            if isCloudBacked(source.path) {
                try await CloudLibrary.primeForGoCoreWrite(path: source.path)
            }
            try await GoCore.shared.setTitle(newTitle, ofCollectionAt: source.path)
            titleRefreshTokens[source.path, default: 0] += 1
        } catch {
            library.importError = error.localizedDescription
        }
    }

    private func removeFromLibrary(_ source: LibrarySource) async {
        await GoCore.shared.invalidateSource(at: source.path)
        try? FileManager.default.removeItem(atPath: source.path)
        library.remove(path: source.path)
        if selectedSource == source { selectedSource = nil }
    }

    private func deleteCollection(_ source: LibrarySource) async {
        await GoCore.shared.invalidateSource(at: source.path)
        do {
            try await CloudLibrary.deleteCoordinated(at: source.path)
        } catch {
            library.importError = error.localizedDescription
            return
        }
        library.remove(path: source.path)
        if selectedSource == source { selectedSource = nil }
    }

    private func isCloudBacked(_ path: String) -> Bool {
        cloudLibrary.items.contains { $0.path == path }
    }

    /// DEBUG-only hook for UI tests: `-uitest-import <path>` runs the real import
    /// pipeline at launch, standing in for the un-automatable system file picker.
    private func runAutomationHookIfRequested() async {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: "uitest-import") else { return }
        await library.importSources(from: [URL(fileURLWithPath: path)])
        #endif
    }

    /// Replaces the Go `Library`'s source set with every collection/bare file currently
    /// known — bundled, imported, and fully-downloaded cloud items — so "Everywhere"
    /// search fans out across all of them.
    private func syncEverywhereSearchSources() async {
        var collections: [String] = []
        var cardFiles: [String] = []

        for source in library.sources {
            switch source {
            case .collection(let path, _): collections.append(path)
            case .cardFile(let path, _): cardFiles.append(path)
            case .singlePostcards: break
            }
        }
        for item in cloudLibrary.items where item.downloadState == .current {
            if item.isCollection {
                collections.append(item.path)
            } else {
                cardFiles.append(item.path)
            }
        }

        try? await GoCore.shared.setLibrarySources(collections: collections, cardFiles: cardFiles)
    }

    /// Resolves a source path (from a `LibraryHit`) to a display name for grouping
    /// "Everywhere" results, across all three places a source can come from.
    private func displayName(forSourcePath path: String) -> String {
        if let match = library.sources.first(where: { $0.path == path }) {
            return match.displayName
        }
        if let match = cloudLibrary.items.first(where: { $0.path == path }) {
            return match.displayName
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

/// The "content" column for a bare `.postcard.*` file source: there's only ever one card,
/// so this just previews it and lets the user commit to viewing it in the detail column.
///
/// Since Feature 2, bare files no longer get their own sidebar row (they live inside
/// "Single postcards"), so this view is currently unreachable in practice; it's kept
/// because `LibrarySource.cardFile` is still a valid case of the selection type.
private struct SingleCardSourceView: View {
    let path: String
    @Binding var selection: CardReference?

    @State private var summary: CardSummary?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let summary {
                Button {
                    selection = .bareFile(path: path, summary: summary)
                } label: {
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 48))
                        Text(summary.name).font(.headline)
                        if let sender = summary.senderName, let recipient = summary.recipientName {
                            Text("\(sender) → \(recipient)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
                .buttonStyle(.plain)
            } else if let loadError {
                ContentUnavailableView("Couldn't open file", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(summary?.name ?? "Postcard")
        .task(id: path) { await load() }
    }

    private func load() async {
        loadError = nil
        do {
            summary = try await GoCore.shared.summary(ofCardFileAt: path)
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// One row in the "Library" sidebar section: a collection's user-set title where one has
/// been set (fetched from the Go core), falling back to `source.displayName` (the filename
/// stem) otherwise.
private struct SourceRow: View {
    let source: LibrarySource
    var refreshToken: Int = 0

    @State private var title: String?

    var body: some View {
        Label(title ?? source.displayName, systemImage: source.isCollection ? "photo.stack" : "photo")
            // Stable machine-facing handle for UI tests — the visible text is the
            // user-set title, which can change without breaking test selectors.
            .accessibilityIdentifier(source.displayName)
            .task(id: "\(source.id)#\(refreshToken)") { await loadTitle() }
    }

    private func loadTitle() async {
        guard source.isCollection else { return }
        if let fetched = try? await GoCore.shared.title(ofCollectionAt: source.path), !fetched.isEmpty {
            title = fetched
        }
    }
}

/// One row in the "iCloud" sidebar section: a normal label once downloaded, or a
/// placeholder with progress while the file is still being fetched. Fully-downloaded
/// collections show their stored title like local sources do; anything not yet local
/// keeps the filename stem — reading a title must never trigger a download.
private struct CloudItemRow: View {
    let item: CloudItem
    var refreshToken: Int = 0

    @State private var title: String?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? item.displayName)
                switch item.downloadState {
                case .current:
                    EmptyView()
                case .downloading(let percent):
                    ProgressView(value: percent, total: 100)
                case .remote:
                    Text("Not downloaded").font(.caption).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.isCollection ? "photo.stack" : "photo")
        }
        .foregroundStyle(item.downloadState == .current ? .primary : .secondary)
        // Keyed on the whole item (plus the rename-refresh token) so the title is fetched
        // once the download completes or a rename lands.
        .task(id: "\(item.id)#\(refreshToken)") { await loadTitle() }
    }

    private func loadTitle() async {
        guard item.isCollection, item.downloadState == .current else { return }
        if let fetched = try? await GoCore.shared.title(ofCollectionAt: item.path), !fetched.isEmpty {
            title = fetched
        }
    }
}
