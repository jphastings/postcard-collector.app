import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// Wraps the non-`Sendable` `CollectionReader` in an actor so the sandboxed preview
/// extension can open a `.postcards` file once and call into it from async SwiftUI tasks
/// without risking concurrent access to its single SQLite connection.
actor CollectionBox {
    private let reader: CollectionReader

    init(path: String) throws {
        reader = try CollectionReader(path: path)
    }

    func cardSummaries() throws -> [CardSummary] { try reader.cardSummaries() }
    func thumbnail(name: String) throws -> Data { try reader.thumbnail(name: name) }
    func imageData(name: String) throws -> Data { try reader.imageData(name: name) }
}

/// The SwiftUI root shown by the QuickLook preview extension for both `.postcard` (a single
/// stacked front+back image) and `.postcards` (a SQLite collection). Built entirely from the
/// Go-free `Postcards/Core`/`Postcards/Views` helpers the main app also uses, so the
/// extension never links the Go core.
struct QuickLookPreviewRoot: View {
    let url: URL

    private struct CardState {
        let front: CGImage
        let back: CGImage?
        let flip: Flip
        let frontPixelSize: CGSize
    }

    private enum Phase {
        case loading
        case failed(String)
        case single(CardState)
        case collection
    }

    @State private var phase: Phase = .loading
    @State private var summaries: [CardSummary] = []
    @State private var collectionBox: CollectionBox?
    @State private var selectedCard: CardState?

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            content
        }
        .task { await load() }
    }

    private var backgroundColor: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .failed(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(24)
        case .single(let card):
            FlippableCardView(front: card.front, back: card.back, flip: card.flip, frontPixelSize: card.frontPixelSize)
                .padding(24)
        case .collection:
            collectionContent
        }
    }

    @ViewBuilder
    private var collectionContent: some View {
        if let selectedCard {
            ZStack(alignment: .topLeading) {
                FlippableCardView(
                    front: selectedCard.front,
                    back: selectedCard.back,
                    flip: selectedCard.flip,
                    frontPixelSize: selectedCard.frontPixelSize
                )
                .padding(24)
                backButton
            }
        } else if let collectionBox {
            MasonryGrid(
                items: summaries,
                aspectRatio: { Double($0.frontPxW) / Double(max($0.frontPxH, 1)) }
            ) { summary in
                CollectionThumbnailCell(box: collectionBox, summary: summary) {
                    await select(name: summary.name, box: collectionBox)
                }
            }
        }
    }

    private var backButton: some View {
        Button {
            withAnimation { selectedCard = nil }
        } label: {
            Image(systemName: "chevron.backward.circle.fill")
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .padding(16)
    }

    // MARK: - Loading

    private func load() async {
        if url.pathExtension.lowercased() == "postcards" {
            await loadCollection()
        } else {
            await loadCard()
        }
    }

    private func loadCard() async {
        do {
            let data = try Data(contentsOf: url)
            let flip = CardFileXMP.flip(in: data) ?? .none
            let split = try ImageSplitter.split(data: data, flip: flip, maxPixelSize: 2400)
            let frontSize = CardFileXMP.frontPixelSize(data: data, flip: flip)
                ?? CGSize(width: split.front.width, height: split.front.height)
            phase = .single(CardState(front: split.front, back: split.back, flip: flip, frontPixelSize: frontSize))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadCollection() async {
        do {
            let box = try CollectionBox(path: url.path)
            let summaries = try await box.cardSummaries()
            collectionBox = box
            self.summaries = summaries
            phase = .collection
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func select(name: String, box: CollectionBox) async {
        guard let summary = summaries.first(where: { $0.name == name }) else { return }
        do {
            let data = try await box.imageData(name: name)
            let split = try ImageSplitter.split(data: data, flip: summary.flip, maxPixelSize: 2000)
            let frontSize = CGSize(width: summary.frontPxW, height: summary.frontPxH)
            withAnimation {
                selectedCard = CardState(front: split.front, back: split.back, flip: summary.flip, frontPixelSize: frontSize)
            }
        } catch {
            // A single bad card shouldn't blank the whole collection preview — leave the
            // grid showing and simply decline to open this one.
        }
    }
}

/// One grid cell: the card's pre-generated thumbnail, decoded once. No edge processing —
/// postcards carry their own soft-alpha matting and should be drawn as-is (see
/// `ImageSplitter`'s doc comment on the same point).
private struct CollectionThumbnailCell: View {
    let box: CollectionBox
    let summary: CardSummary
    let onSelect: () async -> Void

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .aspectRatio(Double(summary.frontPxW) / Double(max(summary.frontPxH, 1)), contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { Task { await onSelect() } }
        .task {
            guard image == nil, let data = try? await box.thumbnail(name: summary.name) else { return }
            guard
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return }
            image = decoded
        }
    }
}
