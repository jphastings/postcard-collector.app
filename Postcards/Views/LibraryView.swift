import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The app's root: a 2-column `NavigationSplitView`. The sidebar column hosts its own
/// `NavigationStack` with two levels — a list of collections (bundled fixtures are gone —
/// see Feature 1; nothing is bundled), then, once one is tapped, a `CollectionBrowser`
/// showing that collection's cards (grid or map, narrowed by any active search). Bare
/// `.postcard.*` files never get their own sidebar row (see Feature 2): they're aggregated
/// into one "Single postcards" row pinned at the bottom, and the union of everything lives
/// behind the "All collections" row pinned at the top. The detail column shows the tapped
/// postcard.
///
/// This collapses what used to be a 3-column split view (sidebar / content / detail) into
/// two: the content column is gone, and the sidebar's own `NavigationStack` push takes its
/// place. That's a deliberate trade against the old design's recurring failure mode — the
/// grid/map mode switcher kept drifting out of place because its home was a `NavigationSplitView`
/// column's *shared* toolbar section, an emergent artifact of how SwiftUI merges each column's
/// own toolbar contributions, and the alternative (an overlay bled into the titlebar band) was
/// unclickable on macOS because AppKit's titlebar owns hit-testing there. A pushed
/// `NavigationStack` destination's toolbar section is stable *by construction*: back/add/
/// switcher all live in the sidebar's own toolbar, in the titlebar, clickable, with nothing
/// else sharing that section. See `CollectionBrowser` and `CollectionModeSwitcher`.
struct LibraryView: View {
    let library: LibraryModel
    let cloudLibrary: CloudLibrary

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The sidebar's own `NavigationStack` path: empty at level 1 (the collections list),
    /// one element once a source is pushed (level 2, the `CollectionBrowser`). Kept as an
    /// array (rather than a single optional) to match `NavigationStack(path:)`'s contract,
    /// even though this design never pushes more than one level from here — `CardDetailView`
    /// pushes a THIRD level on compact width, but through `CompactDetailPush`'s own
    /// `navigationDestination(item:)`, not this path.
    @State private var sidebarPath: [LibrarySource] = []
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

    /// The collection browser's grid/map toggle, lifted here (out of each pane) because the
    /// sidebar column's own width now depends on it too — see `SidebarWidths`. Reset to
    /// `.grid`, alongside `hasAnyLocation` below, whenever `sidebarPath` changes: this state
    /// persists across pushes (unlike the pane-local `@State` it replaces, which started
    /// fresh with every new pane instance), so it has to be reset explicitly or a freshly
    /// opened collection would briefly inherit the previous one's mode/gating.
    @State private var viewMode = CollectionViewMode.grid
    /// Whether the CURRENTLY BROWSED source has any card with a coordinate — gates
    /// `CollectionModeSwitcher`. Written by whichever pane `CollectionBrowser` hosts.
    @State private var hasAnyLocation = false

    private var selectedSource: LibrarySource? { sidebarPath.last }

    #if os(macOS)
    /// Measured geometry feeding `SidebarDestinationFill` — see that modifier's doc comment
    /// for the macOS framework bug this works around. The stack frame and window height are
    /// captured together at the ROOT navigation level (the only time SwiftUI's own frames in
    /// this column are honest); the live window height then tracks resizes, so the usable
    /// bottom edge is always `rootStackMaxY + (windowHeight − windowHeightAtRootCapture)`.
    @State private var sidebarStackFrame: CGRect = .zero
    @State private var windowHeightAtRootCapture: CGFloat = 0
    @State private var windowHeight: CGFloat = 0

    private var sidebarColumnBottom: CGFloat {
        guard sidebarStackFrame != .zero, windowHeightAtRootCapture > 0, windowHeight > 0 else { return 0 }
        return sidebarStackFrame.maxY + (windowHeight - windowHeightAtRootCapture)
    }
    #endif

    var body: some View {
        NavigationSplitView {
            NavigationStack(path: $sidebarPath) {
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
                .toolbar {
                    // Explicit `.primaryAction` placement — matching `CollectionBrowser`'s own
                    // duplicate of this button below (see its comment for why leaving this
                    // `.automatic` is unsafe once a pane with a bottom search bar is pushed) —
                    // so both levels put "Add…" in the same spot rather than having it hop
                    // around as the user pushes/pops. Also duplicated onto `CollectionBrowser`'s
                    // own toolbar below: pushing a destination in this `NavigationStack`
                    // REPLACES the sidebar's toolbar section rather than merging with it
                    // (verified empirically during the restructure's Step 1 spike), so this
                    // root-level item disappears the moment a collection is opened unless it's
                    // repeated there too.
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add…", systemImage: "plus") { isImporting = true }
                    }
                }
                .navigationDestination(for: LibrarySource.self) { source in
                    CollectionBrowser(
                        source: source,
                        selectedCard: $selectedCard,
                        viewMode: $viewMode,
                        hasAnyLocation: $hasAnyLocation,
                        isCompact: horizontalSizeClass == .compact,
                        writableCollections: writableCollections,
                        cloudLibrary: cloudLibrary,
                        searchRequest: searchRequest,
                        onCreateCollection: { try await createCollection(titled: $0) },
                        onFileConsumed: { library.remove(path: $0) },
                        onImport: { isImporting = true },
                        collectionPaths: writableCollections.map(\.path),
                        barePaths: singlePostcardPaths
                    )
                    #if os(macOS)
                    .modifier(SidebarDestinationFill(
                        stackRootFrame: sidebarStackFrame,
                        columnBottom: sidebarColumnBottom
                    ))
                    #endif
                }
            }
            #if os(macOS)
            // Measures the sidebar stack's column-sized frame for `SidebarDestinationFill`.
            // Only while showing the root (collections) level: while a destination is pushed
            // the stack sizes itself to that destination's extent, so a mid-push measurement
            // would echo whatever height the fill modifier just applied instead of the
            // column's real height. The window height is captured alongside so resizes that
            // happen while a destination is pushed can be tracked as a delta.
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { captureRootStackGeometry(proxy.frame(in: .global)) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in captureRootStackGeometry(frame) }
                    .onChange(of: windowHeight) { _, _ in captureRootStackGeometry(proxy.frame(in: .global)) }
            })
            #endif
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
            // State-computed, per `SidebarWidths`: the collections list and a browsed
            // collection's grid mode share the narrower bounds; map mode widens the column so
            // its pins have room to breathe. Animated so the widen/return reads as a resize,
            // not a jump cut (confirmed to animate correctly in the Step 1 spike).
            .navigationSplitViewColumnWidth(
                min: SidebarWidths.bounds(for: viewMode).min,
                ideal: SidebarWidths.bounds(for: viewMode).ideal,
                max: SidebarWidths.bounds(for: viewMode).max
            )
            #endif
        } detail: {
            Group {
                if let selectedCard {
                    CardDetailView(reference: selectedCard, searchRequest: searchRequest)
                } else {
                    ContentUnavailableView("Select a Postcard", systemImage: "photo")
                }
            }
            // Queryable handle for UI tests, which assert this pane's position against the
            // sidebar column (e.g. that it widens in map mode).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("DetailPane")
        }
        // Drives the macOS window title from the sidebar's own push state. A pushed
        // `NavigationStack` destination's `.navigationTitle` (e.g. one set inside
        // `CollectionBrowser`) does NOT reach the window title bar — confirmed empirically in
        // the restructure's Step 1 spike — so it has to be computed here, on the
        // `NavigationSplitView` itself, from `sidebarPath` directly instead.
        //
        // Known gap: this shows `LibrarySource.displayName` (the filename stem), not a
        // collection's user-set title — `CollectionGridView` fetches that title asynchronously
        // for its own `.navigationTitle` (which, per the above, never reaches the window bar
        // anyway) and it isn't hoisted up to here. The two usually match; perfect fidelity
        // would mean lifting the fetched title into `LibraryView` too.
        .navigationTitle(sidebarPath.last.map(\.displayName) ?? "Postcards")
        #if os(macOS)
        // The sidebar's width now ranges up to 700 (map mode) on its own — 800 is comfortably
        // above that plus a usable detail column, and below the old 3-column minimum of 900
        // now that the content column is gone.
        .frame(minWidth: 800, minHeight: 500)
        #endif
        #if os(macOS)
        // AppKit window-height feed for `SidebarDestinationFill`: the one height reference
        // SwiftUI's (distortable — see above) frames can't corrupt.
        .background(WindowHeightReader(height: $windowHeight))
        #endif
        // The window toolbar's background is hidden PERMANENTLY on macOS (15+), not just
        // while a card is selected: macOS only turns the toolbar to liquid glass by itself
        // above scroll views, and a full-height portrait card in the detail pane sits inside
        // the titlebar band (its top would be clipped by an opaque strip otherwise).
        // NSToolbar is one shared bar for the whole window, so this is necessarily global.
        .transparentWindowToolbarBackground()
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
        .onChange(of: sidebarPath) { _, newPath in
            // Every push starts fresh in grid mode, ungated, until the newly pushed pane's
            // own load populates `hasAnyLocation` for real — both persist across pushes (see
            // their declarations above), so they must be reset explicitly here.
            viewMode = .grid
            hasAnyLocation = false
            // A cloud-backed source is only reachable once it's tagged as `.current`, but the
            // path underneath it can still be mid-write from a concurrent iCloud sync; prime
            // it with a short coordinated read before `CollectionBrowser` hands the path to
            // the Go core.
            guard let newSource = newPath.last, cloudLibrary.items.contains(where: { $0.path == newSource.path }) else { return }
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
        // `CompactDetailPush`'s pushed destination back to the collection browser, which is
        // about to show the new search. Regular width (iPad/mac) keeps the detail visible,
        // since its `detail:` column is on screen already.
        .onChange(of: searchRequest.generation) { _, _ in
            guard horizontalSizeClass == .compact else { return }
            selectedCard = nil
        }
    }

    #if os(macOS)
    /// Root-level (collections list) capture for `SidebarDestinationFill` — see the
    /// measurement `background` in `body` for why this must never run while a destination is
    /// pushed. Window height is captured atomically with the stack frame so the pair stays a
    /// consistent baseline for the resize delta.
    private func captureRootStackGeometry(_ frame: CGRect) {
        guard sidebarPath.isEmpty, frame.height > 0, windowHeight > 0 else { return }
        sidebarStackFrame = frame
        windowHeightAtRootCapture = windowHeight
    }
    #endif

    // MARK: - Sidebar

    private var sourceList: some View {
        List {
            Section {
                NavigationLink(value: LibrarySource.allCollections) {
                    Label("All collections", systemImage: "square.stack.3d.up")
                }
                .accessibilityIdentifier("All collections")
            }
            if !importedCollectionSources.isEmpty {
                Section("Library") {
                    ForEach(importedCollectionSources) { source in
                        NavigationLink(value: source) {
                            SourceRow(source: source, refreshToken: titleRefreshTokens[source.path, default: 0])
                        }
                        .contextMenu { importedCollectionMenu(for: source) }
                    }
                }
            }
            if cloudLibrary.containerState == .available, !cloudSidebarItems.isEmpty {
                Section("iCloud") {
                    ForEach(cloudSidebarItems) { item in
                        if item.downloadState == .current {
                            NavigationLink(value: item.librarySource) {
                                CloudItemRow(item: item, refreshToken: titleRefreshTokens[item.path, default: 0])
                            }
                            .contextMenu { cloudCollectionMenu(for: item) }
                        } else {
                            CloudItemRow(item: item, refreshToken: 0)
                        }
                    }
                }
            }
            if hasAnyBareCard {
                Section {
                    NavigationLink(value: LibrarySource.singlePostcards) {
                        Label("Single postcards", systemImage: "photo.on.rectangle.angled")
                    }
                    .accessibilityIdentifier("Single postcards")
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
        if sidebarPath.last == source { sidebarPath.removeLast() }
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
        if sidebarPath.last == source { sidebarPath.removeLast() }
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
            if sidebarPath.last == source {
                sidebarPath[sidebarPath.count - 1] = .collection(path: destinationURL.path, displayName: source.displayName)
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

/// The sidebar's level-2 push destination (`navigationDestination(for: LibrarySource.self)`):
/// hosts whichever pane matches the tapped source, the single `CollectionModeSwitcher`
/// toolbar item that controls it, a duplicate "Add…" (see `LibraryView`'s toolbar comment for
/// why), and the compact-width push to the tapped card's detail (`CompactDetailPush`) — so
/// iPhone gets all three levels (collections list → this browser → card detail) in one
/// `NavigationStack`.
private struct CollectionBrowser: View {
    let source: LibrarySource
    @Binding var selectedCard: CardReference?
    @Binding var viewMode: CollectionViewMode
    @Binding var hasAnyLocation: Bool
    let isCompact: Bool
    var writableCollections: [WritableCollection] = []
    let cloudLibrary: CloudLibrary
    let searchRequest: SearchRequest
    var onCreateCollection: ((String) async throws -> WritableCollection)?
    var onFileConsumed: (String) -> Void = { _ in }
    var onImport: () -> Void
    let collectionPaths: [String]
    let barePaths: [String]

    var body: some View {
        Group {
            switch source {
            case .collection:
                CollectionGridView(
                    source: source,
                    selection: $selectedCard,
                    viewMode: $viewMode,
                    hasAnyLocation: $hasAnyLocation,
                    writableCollections: writableCollections,
                    cloudLibrary: cloudLibrary,
                    searchRequest: searchRequest,
                    onCreateCollection: onCreateCollection
                )
            case .cardFile(let path, _):
                // A bare file reached directly (not via "Single postcards") still routes
                // through the same aggregate grid, just scoped to its own path, so it gets
                // the identical browsing UI (search, context menu, map) as any other bare
                // file rather than a bespoke one-card view.
                SinglePostcardsGridView(
                    paths: [path],
                    selection: $selectedCard,
                    viewMode: $viewMode,
                    hasAnyLocation: $hasAnyLocation,
                    writableCollections: writableCollections,
                    cloudLibrary: cloudLibrary,
                    searchRequest: searchRequest,
                    onFileConsumed: onFileConsumed,
                    onCreateCollection: onCreateCollection
                )
            case .singlePostcards:
                SinglePostcardsGridView(
                    paths: barePaths,
                    selection: $selectedCard,
                    viewMode: $viewMode,
                    hasAnyLocation: $hasAnyLocation,
                    writableCollections: writableCollections,
                    cloudLibrary: cloudLibrary,
                    searchRequest: searchRequest,
                    onFileConsumed: onFileConsumed,
                    onCreateCollection: onCreateCollection
                )
            case .allCollections:
                AllCollectionsView(
                    collectionPaths: collectionPaths,
                    barePaths: barePaths,
                    selection: $selectedCard,
                    viewMode: $viewMode,
                    hasAnyLocation: $hasAnyLocation,
                    cloudLibrary: cloudLibrary,
                    searchRequest: searchRequest
                )
            }
        }
        .modifier(CompactDetailPush(selectedCard: $selectedCard, isCompact: isCompact, searchRequest: searchRequest))
        .toolbar {
            // Duplicated from the sidebar list's own root toolbar: pushing this destination
            // REPLACES the sidebar's toolbar section rather than merging with it (verified
            // empirically during the restructure's Step 1 spike), so the root's own "Add…"
            // would otherwise disappear the instant a collection is opened.
            //
            // EXPLICIT `.primaryAction` placement, not `.automatic`: this destination's content
            // (the grid/map panes) docks `BottomSearchBar` in a bottom `safeAreaInset` on
            // macOS, and an automatic-placement item here risks the sidebar column's bottom
            // bar instead of the titlebar — landing underneath, and hidden/unclickable behind,
            // that search bar. `.primaryAction` pins both items to the top titlebar band,
            // grouped together (Add… then the switcher) right where the sidebar column's own
            // toolbar section ends — regardless of what the pushed content's safe-area insets
            // look like. (`.navigation` was tried for "Add…" first, to sit beside the back
            // chevron, but placed it past the sidebar/detail split instead — `.primaryAction`
            // for both is the more predictable, adjacent pairing.)
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Add…", systemImage: "plus", action: onImport)
                CollectionModeSwitcher(mode: $viewMode, isEnabled: hasAnyLocation)
            }
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

/// On compact-width devices (iPhone), a `NavigationSplitView`'s "detail" column is never made
/// visible by the framework's own navigation once the content column is gone — only
/// `List(selection:)` changes auto-push there, and this design's collection browsers aren't
/// lists. Push the tapped card explicitly within the sidebar's own `NavigationStack` instead
/// (this modifier is applied to `CollectionBrowser`, the stack's level-2 destination, so the
/// pushed card detail becomes level 3); on regular width the `detail:` column already shows it
/// directly, so this is a no-op there.
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

#if os(macOS)
/// Publishes the hosting `NSWindow`'s frame height. `SidebarDestinationFill` needs a height
/// reference that layout inside the window cannot distort: the `NavigationSplitView` (and
/// everything inside it) stretches to hug over-tall sidebar content, so any SwiftUI-side
/// measurement of "the column's bottom" echoes back whatever height the fill modifier itself
/// last applied. The AppKit window frame is immune.
private struct WindowHeightReader: NSViewRepresentable {
    @Binding var height: CGFloat

    func makeNSView(context: NSViewRepresentableContext<WindowHeightReader>) -> WindowHeightTrackingView {
        let view = WindowHeightTrackingView()
        view.onHeightChange = { height = $0 }
        return view
    }

    func updateNSView(_ nsView: WindowHeightTrackingView, context: NSViewRepresentableContext<WindowHeightReader>) {
        nsView.onHeightChange = { height = $0 }
    }
}

private final class WindowHeightTrackingView: NSView {
    var onHeightChange: ((CGFloat) -> Void)?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        guard let window else { return }
        report(window)
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            self?.report(window)
        }
    }

    private func report(_ window: NSWindow) {
        let height = window.frame.height
        DispatchQueue.main.async { [weak self] in
            self?.onHeightChange?(height)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Works around a macOS layout bug in `NavigationStack`-in-sidebar hosting: the sidebar
/// column's stack proposes each pushed `navigationDestination` its IDEAL height rather than
/// the column's, then anchors the undersized result at the column's bottom. None of this
/// design's panes have a meaningful ideal height (`MasonryGrid` is `GeometryReader`-rooted and
/// `Map` accepts anything), so a pushed browser collapsed to just its bottom search bar's
/// height (~44pt), pinned at the bottom of the column, with the rest of the column showing
/// empty sidebar material — in both grid and map modes. The stack's root level is unaffected
/// only because `List` is greedy under the same treatment. (Confirmed empirically on
/// macOS 26.5: an outer `.frame(maxHeight: .infinity)` or `.frame(idealHeight:)` on the
/// destination changes nothing — the tiny height arrives as a real PROPOSAL — while width is
/// always proposed correctly.)
///
/// The workaround sizes the destination explicitly from measured geometry: the destination
/// should reach from wherever the stack places its top (the bottom edge of the navigation
/// band — the strip hosting the back chevron) down to the split view's bottom, so its height
/// is `columnBottom − placedTop`, both measured, no hard-coded band height. The measurement
/// is self-correcting: the first pass (top not yet measured) uses the stack's full height,
/// which over-fills and gets clamped to the band's bottom edge — making the top measurable —
/// and the stack centres any not-exactly-fitting destination in the same region, so each
/// subsequent pass halves any residual error; the fixed point is the exact region fit.
/// The `plausibleTopBand` acceptance filter keeps a transiently-mismeasured pass from
/// collapsing the destination back into the degenerate bottom-bar layout (which would be
/// self-sustaining otherwise, since a bar-sized destination is bottom-anchored and its
/// placed top yields a bar-sized height).
private struct SidebarDestinationFill: ViewModifier {
    /// The stack's frame measured at the ROOT level (the only time it's honestly
    /// column-sized): its height seeds the oversized first pass, and its top bounds which
    /// placement measurements are believable (see `plausibleTopBand`).
    let stackRootFrame: CGRect
    /// The usable content region's bottom edge in global coordinates (measured off the
    /// detail column, which the sidebar's layout can't distort).
    let columnBottom: CGFloat

    /// Where the stack placed this destination (global minY) once layout SETTLED while it
    /// was oversized. In practice this is the bottom edge of the navigation band — an
    /// oversized destination's top always lands there — and it's how the band's height
    /// enters the computed fill height without being hard-coded.
    @State private var placedTop: CGFloat = 0
    /// One-shot latch per input geometry: placement readings are only believable BEFORE a
    /// fitted height is adopted. An undersized destination is bottom-anchored, which makes
    /// every undersized state a fixed point of "height = bottom − placedTop" — re-adopting
    /// a reading after the latch could capture one of those and stick there.
    @State private var latchedInputs: String?
    /// Push/resize animations stream transient placements; only a reading that has stopped
    /// changing for this long is a settled layout.
    @State private var settleTask: Task<Void, Never>?

    /// Accept only placement tops within this distance below the stack's root top. A
    /// region-sized-or-larger destination's top always sits just below the stack top (the
    /// navigation band, ~55pt); anything far lower is a transient from an undersized layout
    /// pass (the stack bottom-anchors those), and folding one into `height` would collapse
    /// the destination back toward the degenerate bottom-bar layout this modifier exists to
    /// prevent.
    private let plausibleTopBand: CGFloat = 200

    private var inputsKey: String { "\(columnBottom)|\(stackRootFrame.minY)|\(stackRootFrame.height)" }

    private var height: CGFloat? {
        if placedTop > 0, columnBottom > placedTop {
            return columnBottom - placedTop
        }
        return stackRootFrame.height > 0 ? stackRootFrame.height : nil
    }

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.frame(in: .global).minY, initial: true) { _, top in
                    guard latchedInputs != inputsKey,
                          top > stackRootFrame.minY - 0.5,
                          top < stackRootFrame.minY + plausibleTopBand
                    else { return }
                    settleTask?.cancel()
                    let key = inputsKey
                    settleTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled else { return }
                        placedTop = top
                        latchedInputs = key
                    }
                }
            })
    }
}

private struct TransparentWindowToolbarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
#endif

private extension View {
    /// See the call site in `LibraryView.body` for why this is applied app-wide.
    func transparentWindowToolbarBackground() -> some View {
        #if os(macOS)
        modifier(TransparentWindowToolbarBackground())
        #else
        self
        #endif
    }
}
