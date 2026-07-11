import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes one already-split postcard face (front or back) for the watch relay stream (see
/// `WatchRelay`). Postcards are die-cut/soft-matted, not hard rectangles, so the result MUST
/// keep the source's alpha channel — this only ever resizes, never smooths or reshapes the
/// alpha edge. The full-resolution split (and, for hand-flip backs, un-rotation) already
/// happened in `ImageSplitter`, so this only downsamples + encodes a single `CGImage`. Kept
/// free of `WatchConnectivity`/`#if os(iOS)` so it's a plain, testable unit (used by
/// `WatchConnectivityProvider`, which is iOS-only).
enum WatchCardImage {
    /// Downsamples `image` to `maxPixelSize` (longest side, never upscaled) and encodes it as
    /// HEIC (small, alpha-capable), falling back to PNG if HEIC encoding is unavailable or
    /// drops the alpha channel — never JPEG, which flattens transparency onto a rectangle.
    /// `nil` if `maxPixelSize` isn't positive or the resize fails.
    static func encodedFace(_ image: CGImage, maxPixelSize: Int) -> Data? {
        guard maxPixelSize > 0, let resized = resized(image, maxPixelSize: maxPixelSize) else { return nil }
        if let heic = encode(resized, as: .heic), preservesAlpha(heic) {
            return heic
        }
        return encode(resized, as: .png)
    }

    /// Draws `image` into a fresh premultiplied-alpha RGBA8 context scaled so its longest side
    /// is at most `maxPixelSize` — a plain resize, never cropped/rotated (that already
    /// happened in `ImageSplitter`) and never smoothed at the alpha edge.
    private static func resized(_ image: CGImage, maxPixelSize: Int) -> CGImage? {
        let longestSide = max(image.width, image.height)
        let scale = longestSide > maxPixelSize ? CGFloat(maxPixelSize) / CGFloat(longestSide) : 1
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    /// Some HEIC encoder configurations silently flatten alpha rather than failing outright,
    /// so a successful encode isn't proof enough on its own — round-trip decode it and check
    /// the result actually carries an alpha plane before trusting it over the PNG fallback.
    private static func preservesAlpha(_ data: Data) -> Bool {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return false }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }
}
