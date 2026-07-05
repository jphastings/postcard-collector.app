import SwiftUI

/// The app's root: a sidebar of collections/loose files (bundled fixtures plus anything
/// the user opens — file importer, ⌘O, drag-and-drop, or Open With), a grid of the
/// selected collection's cards, and the selected card's detail.
struct LibraryView: View {
    let library: LibraryModel
    let cloudLibrary: CloudLibrary

    @State private var selectedSource: LibrarySource?
    @State private var selectedCard: CardReference?
    @State private var isImporting = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedSource) {
                    Section("Library") {
                        ForEach(library.sources) { source in
                            Label(source.displayName, systemImage: source.isCollection ? "photo.stack" : "photo")
                                .tag(source)
                        }
                    }
                    if cloudLibrary.containerState == .available {
                        Section("iCloud") {
                            ForEach(cloudLibrary.items) { item in
                                if item.downloadState == .current {
                                    CloudItemRow(item: item).tag(item.librarySource)
                                } else {
                                    CloudItemRow(item: item)
                                }
                            }
                        }
                    }
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
        } content: {
            if let selectedSource {
                switch selectedSource {
                case .collection:
                    CollectionGridView(source: selectedSource, selection: $selectedCard, resolveSourceName: displayName(forSourcePath:))
                case .cardFile(let path, _):
                    SingleCardSourceView(path: path, selection: $selectedCard)
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

/// One row in the "iCloud" sidebar section: a normal label once downloaded, or a
/// placeholder with progress while the file is still being fetched.
private struct CloudItemRow: View {
    let item: CloudItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
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
    }
}
