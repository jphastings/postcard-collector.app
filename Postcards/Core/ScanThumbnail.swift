import CoreGraphics
import Foundation
import ImageIO

/// Decodes a bounded-size `CGImage` from a scan's raw bytes — `PostcardStage`'s side-card
/// thumbnails and its auto-flipping flip preview both need a quick, small decode of a scan
/// that can be tens of megapixels, never the full resolution just to fill a few hundred points.
enum ScanThumbnail {
    static func decode(from data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
