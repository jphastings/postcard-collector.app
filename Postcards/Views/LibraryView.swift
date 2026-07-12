import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The app's root: a sidebar of collections (bundled fixtures are gone — see Feature 1;
/// nothing is bundled), a grid of the selected collection's cards, and the selected card's
/// detail. Bare `.postcard.*` files never get their own sidebar row (see Feature 2): they're
/// aggregated into one "Single postcards" row pinned at the bottom, and the union of
/// everything lives behind the "All collections" row pinned at the top. The sidebar picks
/// the SCOPE; the content pane lists that scope's postcards (grid or map, narrowed by any
/// active search); the detail pane shows the tapped postcard.
struct LibraryView: View {
    let library: LibraryModel
    let cloudLibrary: CloudLibrary

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedSource: LibrarySource?
    @State private var selectedCard: CardReference?
    @State private var isImporting = false
    /// Search presets submitted from a person's context menu in `CardInfoPanel` — see
    /// `SearchRequest`'s doc comment for why panes key off a bumped `generation`, not the
    /// `token` alone, when picking up a new preset.
    @State private var searchRequest = SearchRequest()

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
                // Default (automatic) placement on both platforms: this renders over the
                // sidebar column's own toolbar section, which is where it belongs and where
                // the user expects it. `.navigation` placement was tried on macOS to dodge
                // the trailing section's ">>" overflow at narrow widths, but that renders
                // the button in the NEXT toolbar section (to the right of the sidebar,
                // outside it) rather than over the sidebar itself — worse than the overflow
                // it was meant to avoid. The overflow risk is instead handled below by
                // giving the sidebar column a minimum width the title + button can't
                // collapse past.
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
            #if os(macOS)
            // The sidebar's own toolbar section has to fit "Postcards" (the navigation
            // title) plus the "Add…" (+) button without either collapsing into the ">>"
            // overflow menu — raised from a 200pt minimum (which let that happen) to 230:
            // comfortably above the ~190-210pt the title + button need at the system font's
            // default size, with a little headroom for wider titles/Dynamic-Type-like
            // scaling. Worth eyeballing on-device across a couple of window sizes, since
            // exact toolbar-item measurement isn't available at this layer.
            .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
            #endif
        } content: {
            Group {
                if !hasAnySources {
                    emptyLibraryView
                } else if let selectedSource {
                    switch selectedSource {
                    case .collection:
                        CollectionGridView(
                            source: selectedSource,
                            selection: $selectedCard,
                            writableCollections: writableCollections,
                            cloudLibrary: cloudLibrary,
                            searchRequest: searchRequest,
                            onCreateCollection: { try await createCollection(titled: $0) }
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
                            searchRequest: searchRequest,
                            onFileConsumed: { library.remove(path: $0) },
                            onCreateCollection: { try await createCollection(titled: $0) }
                        )
                    case .allCollections:
                        AllCollectionsView(
                            collectionPaths: writableCollections.map(\.path),
                            barePaths: singlePostcardPaths,
                            selection: $selectedCard,
                            cloudLibrary: cloudLibrary,
                            searchRequest: searchRequest
                        )
                    }
                } else {
                    ContentUnavailableView("Select a Collection", systemImage: "photo.stack.fill")
                }
            }
            .modifier(CompactDetailPush(selectedCard: $selectedCard, isCompact: horizontalSizeClass == .compact, searchRequest: searchRequest))
            #if os(macOS)
            // Wide enough that the pane's own toolbar items (e.g. `CollectionModeSwitcher`)
            // never detach into overflow as the column narrows.
            .navigationSplitViewColumnWidth(min: 300, ideal: 420)
            #endif
        } detail: {
            if let selectedCard {
                CardDetailView(reference: selectedCard, searchRequest: searchRequest)
            } else {
                // iOS ONLY: mirrors `CardDetailView`'s at-rest (unzoomed) detail-column
                // toolbar contribution, so a `NavigationSplitView`'s per-column toolbar merge
                // sees an identical shape whether or not a card is selected — otherwise the
                // content column's own `.primaryAction` toolbar item (`CollectionModeSwitcher`)
                // would shift position depending on what the detail column happens to
                // contain (see that type's doc comment). `CardDetailView` keeps an
                // unconditional (i) in its own `ToolbarItemGroup` on iOS, so this stands in
                // with a disabled one to match.
                //
                // macOS has no equivalent block below: `CollectionModeSwitcher` no longer
                // lives in the content column's toolbar there at all (it's an in-pane
                // overlay now — see its doc comment), so the content column contributes
                // nothing for the detail column to match regardless of selection, and this
                // mirroring is moot on that platform. (For the curious: `CardDetailView`'s
                // own macOS (i) lives on the `.inspector` content's toolbar instead — see
                // `CardDetailView.infoPanel` — which was the other half of why this used to
                // need matching there too.)
                ContentUnavailableView("Select a Postcard", systemImage: "photo")
                    #if os(iOS)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Info", systemImage: "info.circle") {}
                                .disabled(true)
                        }
                    }
                    #endif
            }
        }
        #if os(macOS)
        // Sidebar + content minimums above, plus a little room for the detail column, so
        // all three columns always fit without the window forcing one of them narrower.
        .frame(minWidth: 900, minHeight: 500)
        #endif
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
        // Keeps the "All collections" search fan-out current as sources are imported,
        // removed, or synced in from iCloud.
        .onChange(of: library.sources, initial: true) { _, _ in
            Task { await syncLibrarySearchSources() }
        }
        .onChange(of: cloudLibrary.items, initial: true) { _, _ in
            Task { await syncLibrarySearchSources() }
        }
        // On iPhone (compact width), a search preset from `CardInfoPanel`'s "More from…"
        // menu should land the user back on the grid of results, not leave them stuck on
        // the detail view they tapped the preset from — popping `selectedCard` collapses
        // `CompactDetailPush`'s pushed destination back to the content column, which is
        // about to show the new search. Regular width (iPad/mac) keeps the detail visible,
        // since its `detail:` column and the content column are both on screen already.
        .onChange(of: searchRequest.generation) { _, _ in
            guard horizontalSizeClass == .compact else { return }
            selectedCard = nil
        }
    }

    // MARK: - Sidebar

    private var sourceList: some View {
        List(selection: $selectedSource) {
            Section {
                Label("All collections", systemImage: "square.stack.3d.up")
                    .accessibilityIdentifier("All collections")
                    .tag(LibrarySource.allCollections)
            }
            if !importedCollectionSources.isEmpty {
                Section("Library") {
                    ForEach(importedCollectionSources) { source in
                        SourceRow(source: source, refreshToken: titleRefreshTokens[source.path, default: 0])
                            .tag(source)
                            .contextMenu { importedCollectionMenu(for: source) }
                    }
                }
            }
            if cloudLibrary.containerState == .available, !cloudSidebarItems.isEmpty {
                Section("iCloud") {
                    ForEach(cloudSidebarItems) { item in
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

    /// The "Library" sidebar section's rows: imported collections, minus any whose path is
    /// also an iCloud item — a collection created in the iCloud folder by the
    /// "New collection…" flow is registered in `library.sources` for instant visibility,
    /// then moves to the iCloud section once `CloudLibrary`'s metadata query notices it.
    private var importedCollectionSources: [LibrarySource] {
        library.sources.filter { source in
            source.isCollection && !cloudLibrary.items.contains { $0.path == source.path }
        }
    }

    /// The "iCloud" sidebar section's rows: fully-downloaded bare files move into "Single
    /// postcards" below instead (aggregating them before they exist locally would just mean
    /// showing progress rows in two places), so only collections and not-yet-downloaded bare
    /// files stay here.
    private var cloudSidebarItems: [CloudItem] {
        cloudLibrary.items.filter { $0.isCollection || $0.downloadState != .current }
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
    /// Deduplicated by path: a just-created iCloud collection can briefly be in both
    /// `library.sources` (registered for instant visibility) and `cloudLibrary.items`.
    private var writableCollections: [WritableCollection] {
        var collections = library.sources.compactMap { source -> WritableCollection? in
            guard case .collection(let path, let name) = source else { return nil }
            return WritableCollection(path: path, displayName: name)
        }
        collections += cloudLibrary.items
            .filter { $0.isCollection && $0.downloadState == .current }
            .map { WritableCollection(path: $0.path, displayName: $0.displayName) }

        var seen = Set<String>()
        return collections.filter { seen.insert($0.path).inserted }
    }

    // MARK: - Sidebar row actions (Feature 3)

    @ViewBuilder
    private func importedCollectionMenu(for source: LibrarySource) -> some View {
        Button("Rename…") {
            renameText = source.displayName
            renamingSource = source
        }
        if cloudLibrary.containerState == .available {
            Button("Add to iCloud…") {
                Task { await addToICloud(source) }
            }
        }
        revealInFinderButton(path: source.path)
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
        // For iCloud items this reveals the LOCAL ubiquity URL — the synced file under
        // ~/Library/Mobile Documents, which Finder presents as the iCloud Drive folder.
        revealInFinderButton(path: item.path)
        Divider()
        // No "Remove from Library" here: iCloud collections come from the folder scan,
        // so "removing" one from the sidebar without deleting the file would just have it
        // reappear on the next `NSMetadataQuery` update. Only a real deletion is meaningful.
        Button("Delete…", role: .destructive) {
            pendingDeletion = item.librarySource
        }
    }

    /// macOS only: every real-file source can be revealed; iOS has no Finder (and Files
    /// has no equivalent API), so the menus simply don't offer it there.
    @ViewBuilder
    private func revealInFinderButton(path: String) -> some View {
        #if os(macOS)
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        #endif
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

    /// Registers the moved file as a source immediately, same reasoning as
    /// `createCollection`: instant visibility, then it moves to the iCloud section once
    /// `CloudLibrary`'s metadata query notices it.
    private func addToICloud(_ source: LibrarySource) async {
        guard let documentsURL = cloudLibrary.documentsURL else { return }
        let sourceURL = URL(fileURLWithPath: source.path)
        let destinationURL = documentsURL.appending(path: sourceURL.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            library.importError = "A collection file named “\(sourceURL.lastPathComponent)” already exists in iCloud."
            return
        }
        await GoCore.shared.invalidateSource(at: source.path)
        do {
            try await CloudLibrary.moveToCloud(from: source.path, to: destinationURL)
            library.remove(path: source.path)
            library.registerCollection(at: destinationURL)
            if selectedSource == source {
                selectedSource = .collection(path: destinationURL.path, displayName: source.displayName)
            }
        } catch {
            library.importError = error.localizedDescription
        }
    }

    // MARK: - New collection… (grid context menus)

    private struct NewCollectionError: LocalizedError {
        let errorDescription: String?
    }

    /// Creates a new, empty collection for the grids' "New collection…" flow and returns
    /// it as a move/copy target. Location: the iCloud Postcards Documents folder when the
    /// ubiquity container is available — so it syncs and shows up on other devices like
    /// any collection dropped there — otherwise the local ImportedSources directory, the
    /// same place imports live, so `LibraryModel` restores it at the next launch.
    /// Registered as a source immediately either way; a filename collision errors rather
    /// than overwriting (keeping the title dialog simple).
    private func createCollection(titled title: String) async throws -> WritableCollection {
        let filename = CollectionNaming.filename(forTitle: title)
        let directory: URL
        if cloudLibrary.containerState == .available, let documents = cloudLibrary.documentsURL {
            directory = documents
        } else {
            directory = LibraryModel.defaultImportDirectory
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: filename)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NewCollectionError(errorDescription: "A collection file named “\(filename)” already exists.")
        }

        try await GoCore.shared.createCollection(at: url.path, title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        library.registerCollection(at: url)
        return WritableCollection(path: url.path, displayName: CollectionNaming.stem(forTitle: title))
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
    /// known — imported and fully-downloaded cloud items — so "All collections" search
    /// fans out across all of them (see `AllCollectionsView`).
    private func syncLibrarySearchSources() async {
        var collections: [String] = []
        var cardFiles: [String] = []

        for source in library.sources {
            switch source {
            case .collection(let path, _): collections.append(path)
            case .cardFile(let path, _): cardFiles.append(path)
            case .singlePostcards, .allCollections: break
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

/// On compact-width devices (iPhone), `NavigationSplitView`'s third "detail" column is
/// never made visible by the framework's own navigation — only `List(selection:)` changes
/// auto-push there, and the content pane's masonry grids aren't lists. Push the tapped
/// card explicitly within the content column's own navigation stack instead; on regular
/// width the `detail:` column already shows it directly, so this is a no-op there.
private struct CompactDetailPush: ViewModifier {
    @Binding var selectedCard: CardReference?
    let isCompact: Bool
    let searchRequest: SearchRequest

    func body(content: Content) -> some View {
        if isCompact {
            content.navigationDestination(item: $selectedCard) { card in
                CardDetailView(reference: card, searchRequest: searchRequest)
            }
        } else {
            content
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
