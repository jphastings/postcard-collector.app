import CoreGraphics
import SwiftUI

/// One postcard, filling one screen of `WatchPostcardScrollView`'s snap-scroll. Owns both of
/// its gestures on a single container — a single tap flips the card, a double tap toggles a
/// 2.5x zoom — rather than nesting a second tap recognizer inside `FlippableCardView`'s own,
/// which is exactly the ambiguity `tapToFlip`/`isFlipped` were added to `FlippableCardView`
/// to avoid: SwiftUI cleanly disambiguates single- vs double-tap only when both gestures are
/// attached to the same view.
struct WatchCardView: View {
    let store: WatchCollectionStore
    let summary: CardSummary
    /// Reported up to the scroll view so it can disable paging while this card is zoomed —
    /// set to this card's name while zoomed, `nil` once the zoom resets.
    @Binding var zoomedCardID: String?

    private static let zoomScale: CGFloat = 2.5

    private enum LoadState {
        case loading
        case failed(String)
        case loaded(front: CGImage, back: CGImage?)
    }

    @State private var loadState: LoadState = .loading
    @State private var isFlipped = false
    @State private var isZoomed = false
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var containerSize: CGSize = .zero

    var body: some View {
        content
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView(
                "Can't Load Card",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded(let front, let back):
            FlippableCardView(
                front: front,
                back: back,
                flip: summary.flip,
                frontPixelSize: CGSize(width: summary.frontPxW, height: summary.frontPxH),
                tapToFlip: false,
                isFlipped: $isFlipped
            )
            .padding(8)
            .background {
                // Captured before scale/offset so drag translation and the zoom clamp both
                // work in one stable, unscaled coordinate space — see `ZoomGeometry`.
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { containerSize = proxy.size }
                        .onChange(of: proxy.size) { _, newValue in containerSize = newValue }
                }
            }
            .scaleEffect(scale)
            .offset(offset)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleZoom() }
            .onTapGesture(count: 1) { isFlipped.toggle() }
            .simultaneousGesture(panGesture)
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard isZoomed else { return }
                let proposed = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
                offset = ZoomGeometry.clampedOffset(proposed, scale: scale, containerSize: containerSize)
            }
            .onEnded { _ in
                guard isZoomed else { return }
                lastOffset = offset
            }
    }

    private func toggleZoom() {
        let zooming = !isZoomed
        withAnimation(.easeInOut(duration: 0.25)) {
            isZoomed = zooming
            scale = zooming ? Self.zoomScale : 1
            if !zooming {
                offset = .zero
                lastOffset = .zero
            }
        }
        zoomedCardID = zooming ? summary.name : nil
    }

    private func load() async {
        do {
            let data = try await store.imageData(name: summary.name)
            let split = try ImageSplitter.split(data: data, flip: summary.flip, maxPixelSize: 480)
            loadState = .loaded(front: split.front, back: split.back)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}
