import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downsamples a card's stored (combined front+back) image for the watch relay stream (see
/// `WatchRelay`). Postcards are die-cut/soft-matted, not hard rectangles, so the result MUST
/// keep the source's alpha channel — this only ever resizes, never smooths or reshapes the
/// alpha edge. Kept free of `WatchConnectivity`/`#if os(iOS)` so it's a plain, testable unit
/// (used by `WatchConnectivityProvider`, which is iOS-only).
enum WatchCardImage {
    /// Longest side, in pixels, of the downsampled combined image. The combined image is
    /// front stacked on back, so each side lands at roughly half this — about 900px, plenty
    /// for the watch's 2.5x double-tap zoom.
    static let maxPixelSize = 1800

    /// Decodes `data`, downsamples it to `maxPixelSize`, and re-encodes it as HEIC (small,
    /// alpha-capable). Falls back to PNG if HEIC encoding is unavailable or drops the alpha
    /// channel — never JPEG, which flattens transparency onto a rectangle. `nil` if `data`
    /// can't be decoded at all.
    static func downsampled(_ data: Data, maxPixelSize: Int = maxPixelSize) -> Data? {
        guard let thumbnail = thumbnailImage(from: data, maxPixelSize: maxPixelSize) else { return nil }
        if let heic = encode(thumbnail, as: .heic), preservesAlpha(heic) {
            return heic
        }
        return encode(thumbnail, as: .png)
    }

    private static func thumbnailImage(from data: Data, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
