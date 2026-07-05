import SwiftUI

/// Shows one postcard full-size: a tap-to-flip 3D card, plus an info sheet/inspector with
/// its metadata.
struct CardDetailView: View {
    let reference: CardReference

    @State private var splitImage: SplitPostcardImage?
    @State private var metadata: PostcardMetadata?
    @State private var loadError: String?
    @State private var showingInfo = false

    var body: some View {
        content
            .navigationTitle(reference.summary.name)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Info", systemImage: "info.circle") {
                        showingInfo.toggle()
                    }
                    .disabled(metadata == nil)
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showingInfo) { infoPanel }
            #else
            .inspector(isPresented: $showingInfo) { infoPanel }
            #endif
            .task(id: reference.id) { await load() }
    }

    @ViewBuilder
    private var infoPanel: some View {
        if let metadata {
            CardInfoPanel(summary: reference.summary, metadata: metadata)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let splitImage {
            FlippableCardView(
                front: splitImage.front,
                back: splitImage.back,
                flip: reference.summary.flip,
                frontPixelSize: CGSize(
                    width: CGFloat(reference.summary.frontPxW),
                    height: CGFloat(reference.summary.frontPxH)
                )
            )
            .padding(40)
        } else if let loadError {
            ContentUnavailableView(
                "Couldn't load postcard",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else {
            ProgressView()
        }
    }

    private func load() async {
        splitImage = nil
        loadError = nil
        let flip = reference.summary.flip
        do {
            async let imageData = GoCore.shared.image(for: reference)
            async let loadedMetadata = GoCore.shared.metadata(for: reference)
            let (data, resolvedMetadata) = try await (imageData, loadedMetadata)

            splitImage = try await Task.detached(priority: .userInitiated) {
                try ImageSplitter.split(data: data, flip: flip)
            }.value
            metadata = resolvedMetadata
        } catch {
            loadError = error.localizedDescription
        }
    }
}
