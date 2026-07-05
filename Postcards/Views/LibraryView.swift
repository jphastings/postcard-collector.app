import SwiftUI

/// The app's root: a sidebar of collections/loose files (bundled fixtures plus anything
/// opened via `.fileImporter`), a grid of the selected collection's cards, and the
/// selected card's detail.
struct LibraryView: View {
    @State private var library = LibraryModel()
    @State private var selectedSource: LibrarySource?
    @State private var selectedCard: CardReference?
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        NavigationSplitView {
            List(library.sources, selection: $selectedSource) { source in
                Label(source.displayName, systemImage: source.isCollection ? "photo.stack" : "photo")
                    .tag(source)
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
                    library.addSources(from: urls)
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .alert(
                "Couldn't open file",
                isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        } content: {
            if let selectedSource {
                switch selectedSource {
                case .collection:
                    CollectionGridView(source: selectedSource, selection: $selectedCard)
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
