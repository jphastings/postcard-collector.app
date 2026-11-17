import SwiftUI

/// The standard "this card is open in the detail pane" treatment for a masonry grid cell
/// (`CollectionGridView`/`SinglePostcardsGridView`/`AllCollectionsView`): the Photos-style
/// crisp accent outline, traced around the thumbnail's own silhouette so die-cut cards are
/// outlined along their real edge (opaque cards come out as a box). The ring is the image's
/// alpha dilated by `gap + lineWidth`, minus it dilated by `gap` — so it never tints soft,
/// fibrous edges, and the image is never clipped, plated or reshaped. `MasonryGrid`'s padding and
/// spacing leave room for it. Identical on iOS and macOS.
private struct GridSelectionHighlight: ViewModifier {
    let isSelected: Bool
    let image: PlatformImage?

    private let lineWidth: CGFloat = 3
    private let gap: CGFloat = 1.5
    private let dilationSteps = 16

    func body(content: Content) -> some View {
        content
            .overlay {
                outline
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    @ViewBuilder
    private var outline: some View {
        if let image {
            ZStack {
                dilated(image, by: gap + lineWidth)
                ZStack {
                    silhouette(of: image)
                    dilated(image, by: gap)
                }
                .blendMode(.destinationOut)
            }
            .compositingGroup()
        } else {
            RoundedRectangle(cornerRadius: lineWidth)
                .inset(by: -(gap + lineWidth / 2))
                .stroke(Color.accentColor, lineWidth: lineWidth)
        }
    }

    private func dilated(_ image: PlatformImage, by radius: CGFloat) -> some View {
        ZStack {
            ForEach(0..<dilationSteps, id: \.self) { step in
                let angle = Double(step) / Double(dilationSteps) * 2 * .pi
                silhouette(of: image)
                    .offset(x: cos(angle) * radius, y: sin(angle) * radius)
            }
        }
    }

    /// Must match the cell's own `.resizable().scaledToFill()` so the ring lines up.
    private func silhouette(of image: PlatformImage) -> some View {
        Color.accentColor.mask {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
        }
    }
}

#if os(macOS)
/// Small tilt-on-hover for grid thumbnails: the same `ParallaxGeometry` hover mapping the
/// card-detail flip uses, at a reduced maximum so it reads as a gentle nudge rather than the
/// detail view's lean. macOS only — there's no pointer hover to drive this on iOS.
private struct ThumbnailHoverParallax: ViewModifier {
    /// Noticeably smaller than the detail view's `ParallaxGeometry.maxDegrees` (4°): this is
    /// a small grid-cell polish detail, not the main event.
    static let maxDegrees: Double = 2.5

    @State private var size: CGSize = .zero
    @State private var tilt = ParallaxGeometry.Tilt.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, newValue in size = newValue }
                }
            }
            .rotation3DEffect(.degrees(tilt.y), axis: (x: 1, y: 0, z: 0), perspective: 0.3)
            .rotation3DEffect(.degrees(tilt.x), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    withAnimation(.easeOut(duration: 0.12)) {
                        tilt = ParallaxGeometry.tilt(hoverLocation: location, in: size, reduceMotion: reduceMotion, maxDegrees: Self.maxDegrees)
                    }
                case .ended:
                    withAnimation(.easeOut(duration: 0.3)) {
                        tilt = .zero
                    }
                }
            }
    }
}
#endif

extension View {
    /// See `GridSelectionHighlight`. `image` should be the thumbnail the cell displays, so
    /// the outline traces what's on screen; pass `nil` while it's still loading.
    func gridSelectionHighlight(_ isSelected: Bool, image: PlatformImage?) -> some View {
        modifier(GridSelectionHighlight(isSelected: isSelected, image: image))
    }

    /// Applies `ThumbnailHoverParallax` on macOS; a no-op elsewhere (see that type's doc).
    func thumbnailHoverParallax() -> some View {
        #if os(macOS)
        modifier(ThumbnailHoverParallax())
        #else
        self
        #endif
    }
}
