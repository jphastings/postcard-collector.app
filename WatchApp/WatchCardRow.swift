import CoreGraphics
import ImageIO
import SwiftUI

/// One row in `WatchCollectionView`'s list: thumbnail-first, so layout never waits on a
/// decode — the row's aspect ratio comes straight from `CardSummary.frontPxW/H`. Tapping
/// loads the full combined image, splits it, and swaps in a `FlippableCardView` (its own tap
/// then flips it; its `ParallaxModel` starts on appear, giving accelerometer parallax on
/// watch too). No edge processing on any decoded image — postcards carry their own soft-alpha
/// matting and must be drawn as-is.
struct WatchCardRow: View {
    let store: WatchCollectionStore
    let summary: CardSummary

    private enum RowState {
        case thumbnail(CGImage?)
        case loadingFull
        case full(front: CGImage, back: CGImage?)
    }

    @State private var state: RowState = .thumbnail(nil)

    private var aspectRatio: Double {
        Double(summary.frontPxW) / Double(max(summary.frontPxH, 1))
    }

    var body: some View {
        Group {
            switch state {
            case .thumbnail(let image):
                thumbnailView(image)
                    .task { await loadThumbnailIfNeeded() }
                    .onTapGesture { Task { await loadFull() } }
            case .loadingFull:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .aspectRatio(aspectRatio, contentMode: .fit)
            case .full(let front, let back):
                FlippableCardView(
                    front: front,
                    back: back,
                    flip: summary.flip,
                    frontPixelSize: CGSize(width: summary.frontPxW, height: summary.frontPxH)
                )
            }
        }
    }

    @ViewBuilder
    private func thumbnailView(_ image: CGImage?) -> some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .contentShape(Rectangle())
    }

    private func loadThumbnailIfNeeded() async {
        guard case .thumbnail(nil) = state else { return }
        guard let data = try? await store.thumbnail(name: summary.name), let decoded = Self.decode(data) else { return }
        if case .thumbnail = state {
            state = .thumbnail(decoded)
        }
    }

    private func loadFull() async {
        state = .loadingFull
        do {
            let data = try await store.imageData(name: summary.name)
            let split = try ImageSplitter.split(data: data, flip: summary.flip, maxPixelSize: 480)
            state = .full(front: split.front, back: split.back)
        } catch {
            // A single bad card shouldn't strand the row on a spinner — fall back to
            // whatever thumbnail we already had.
            let data = try? await store.thumbnail(name: summary.name)
            state = .thumbnail(data.flatMap(Self.decode))
        }
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
