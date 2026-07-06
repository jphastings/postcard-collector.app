import SwiftUI

/// The standard "this card is open in the detail pane" treatment for a masonry grid cell
/// (`CollectionGridView`/`SinglePostcardsGridView`/`AllCollectionsView`): an accent ring plus
/// a soft glow around the thumbnail's own bounds. Deliberately NOT a background plate —
/// postcards can have real transparency (die-cut/torn scans), so a filled plate behind a
/// transparent silhouette would show through as a fake rectangular border (see `GridCell`'s
/// doc comment). Identical on iOS and macOS.
private struct GridSelectionHighlight: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if isSelected {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .shadow(color: .accentColor.opacity(0.7), radius: 5)
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
    /// See `GridSelectionHighlight`.
    func gridSelectionHighlight(_ isSelected: Bool) -> some View {
        modifier(GridSelectionHighlight(isSelected: isSelected))
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
