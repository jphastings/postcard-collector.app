import SwiftUI

/// The standard "this card is open in the detail pane" treatment for a masonry grid cell
/// (`CollectionGridView`/`SinglePostcardsGridView`/`AllCollectionsView`): a soft accent glow
/// that follows the thumbnail's own alpha, rather than a crisp rectangular outline.
/// Deliberately NOT a background plate — postcards can have real transparency (die-cut/torn
/// scans), so a filled plate behind a transparent silhouette would show through as a fake
/// rectangular border (see `GridCell`'s doc comment); masking the glow to the image's alpha
/// keeps it hugging the postcard's actual shape instead. Identical on iOS and macOS.
private struct GridSelectionHighlight: ViewModifier {
    let isSelected: Bool
    let image: PlatformImage?

    func body(content: Content) -> some View {
        content
            .background {
                if isSelected {
                    Group {
                        if let image {
                            // .mask only ever READS this image's existing alpha channel — it
                            // must never threshold or reshape it, since postcards' soft
                            // fibrous/die-cut edges are load-bearing detail, not noise.
                            // Opaque thumbnails (no alpha) mask to the full rectangle, so
                            // collection cards still get today's rectangular glow.
                            Color.accentColor
                                .mask {
                                    Image(platformImage: image)
                                        .resizable()
                                        .scaledToFill()
                                }
                        } else {
                            // Thumbnail still loading: fall back to a plain rounded-rect glow
                            // until the real alpha shape is available to mask against.
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor)
                        }
                    }
                    .blur(radius: 8)
                    .opacity(0.8)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isSelected)
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
    /// See `GridSelectionHighlight`. `image` should be the same thumbnail the cell displays,
    /// so the glow's mask lines up with what's on screen; pass `nil` while it's still loading.
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
