import SwiftUI

/// A bare `.postcard.*` file shown on its own. These are never kept in the library: macOS gives
/// each one its own window (the "postcard" scene), iOS presents it full screen over the library.
/// "Add to Collection" copies it into a collection, leaving the file itself alone.
struct SinglePostcardView: View {
    static let windowID = "postcard"

    let url: URL
    let library: LibraryModel
    let cloudLibrary: CloudLibrary

    @State private var summary: CardSummary?
    @State private var loadError: String?
    @State private var addedTo: String?
    @State private var addError: String?
    /// Not wired anywhere: there's no grid here for an info panel's "More from…" to search.
    @State private var searchRequest = SearchRequest()

    private var reference: CardReference? {
        summary.map { .bareFile(path: url.path, summary: $0) }
    }

    var body: some View {
        Group {
            if let reference {
                CardDetailView(reference: reference, searchRequest: searchRequest)
            } else if let loadError {
                ContentUnavailableView("Couldn't Open Postcard", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(summary?.name ?? url.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .navigation) { addToCollectionMenu }
        }
        .postcardExporting(openCard: reference)
        .task(id: url) { await load() }
        .alert(
            "Couldn't add postcard",
            isPresented: Binding(get: { addError != nil }, set: { if !$0 { addError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addError ?? "")
        }
    }

    private var addToCollectionMenu: some View {
        let collections = library.writableCollections(with: cloudLibrary)
        return Menu {
            ForEach(collections) { collection in
                Button(collection.displayName) { Task { await add(to: collection) } }
            }
        } label: {
            Label(addLabel, systemImage: addedTo == nil ? "rectangle.stack.badge.plus" : "checkmark.rectangle.stack")
        }
        .labelStyle(.iconOnly)
        .help(addLabel)
        .disabled(summary == nil || collections.isEmpty)
    }

    private var addLabel: String {
        addedTo.map { "Added to \($0)" } ?? "Add to Collection"
    }

    private func load() async {
        do {
            summary = try await GoCore.shared.summary(ofCardFileAt: url.path)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func add(to collection: WritableCollection) async {
        guard let summary else { return }
        do {
            let data = try await GoCore.shared.image(ofCardFileAt: url.path)
            if cloudLibrary.items.contains(where: { $0.path == collection.path }) {
                try await CloudLibrary.primeForGoCoreWrite(path: collection.path)
            }
            _ = try await GoCore.shared.addCard(filename: summary.filename, data: data, toCollectionAt: collection.path)
            library.contentGeneration += 1
            addedTo = collection.displayName
        } catch {
            addError = error.localizedDescription
        }
    }
}

#if os(macOS)
/// Opens files on macOS: bare cards each get their own `SinglePostcardView` window; anything
/// else (collections, or files that failed and need their error shown) brings up the single
/// collections window, which may have been closed.
@MainActor
func openPostcardFiles(_ urls: [URL], library: LibraryModel, openWindow: OpenWindowAction) async {
    let cards = await library.importSources(from: urls)
    for card in cards {
        openWindow(id: SinglePostcardView.windowID, value: card)
    }
    if cards.count < urls.count {
        openWindow(id: LibraryView.windowID)
    }
}

/// Handles Finder double-clicks / "Open With" in whichever window receives them.
private struct OpensPostcardFiles: ViewModifier {
    let library: LibraryModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onOpenURL { url in
            Task { await openPostcardFiles([url], library: library, openWindow: openWindow) }
        }
    }
}

extension View {
    func opensPostcardFiles(library: LibraryModel) -> some View {
        modifier(OpensPostcardFiles(library: library))
    }
}
#endif
