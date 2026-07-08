import AppKit
import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing

/// The macOS Quick Look thumbnail extension's entry point. Draws directly into the reply's
/// `CGContext` rather than hosting SwiftUI — thumbnails are requested far more often, and at
/// far smaller sizes, than previews, so a plain ImageIO/CoreGraphics decode is both simpler
/// and cheaper here.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let images = try Self.thumbnailImages(for: request)
                let reply = QLThumbnailReply(contextSize: request.maximumSize) {
                    Self.draw(images, in: request.maximumSize)
                    return true
                }
                handler(reply, nil)
            } catch {
                handler(nil, error)
            }
        }
    }

    // MARK: - Loading

    /// The front-facing `CGImage`s to draw, decoded at (roughly) the requested size. For a
    /// bare `.postcard` this is the single front image; for a `.postcards` collection it's
    /// up to the first three cards' pre-generated thumbnails, most-recent first (see
    /// `CollectionReader.cardSummaries`'s ordering), fanned out by `draw(_:in:)`.
    private static func thumbnailImages(for request: QLFileThumbnailRequest) throws -> [CGImage] {
        let maxPixelSize = Int(max(request.maximumSize.width, request.maximumSize.height).rounded(.up))

        if request.fileURL.pathExtension.lowercased() == "postcards" {
            let reader = try CollectionReader(path: request.fileURL.path)
            let summaries = try reader.cardSummaries().prefix(3)
            return try summaries.compactMap { summary in
                let data = try reader.thumbnail(name: summary.name)
                return decodedImage(from: data)
            }
        } else {
            let data = try Data(contentsOf: request.fileURL)
            let flip = CardFileXMP.flip(in: data) ?? .none
            let split = try ImageSplitter.split(data: data, flip: flip, maxPixelSize: maxPixelSize)
            return [split.front]
        }
    }

    private static func decodedImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: - Drawing

    /// Draws into the current `CGContext` (AppKit's coordinate system, as supplied by
    /// `currentContextDrawing`'s block). A single image is drawn aspect-fit and centred; a
    /// collection's first few cards are fanned out as a slightly rotated, offset pile, with
    /// the most recent card (`images[0]`) both dead-centre and drawn last, on top. Respects
    /// the postcards' own soft-alpha edge matting — no additional masking/edge processing.
    private static func draw(_ images: [CGImage], in size: CGSize) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        guard !images.isEmpty else {
            drawPlaceholder(in: size, context: context)
            return
        }

        let cardBox = CGRect(
            x: size.width * 0.14,
            y: size.height * 0.14,
            width: size.width * 0.72,
            height: size.height * 0.72
        )

        guard images.count > 1 else {
            drawAspectFit(images[0], in: cardBox, context: context)
            return
        }

        let anglePerCard: CGFloat = 8 * .pi / 180
        let offsetPerCard = min(size.width, size.height) * 0.05
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        // Drawn back-to-front (highest index first) so `images[0]` lands on top.
        for index in stride(from: images.count - 1, through: 0, by: -1) {
            let depth = CGFloat(index)
            let direction: CGFloat = index.isMultiple(of: 2) ? 1 : -1

            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: depth * anglePerCard * direction)
            context.translateBy(x: depth * offsetPerCard * direction - center.x, y: -center.y)
            drawAspectFit(images[index], in: cardBox, context: context)
            context.restoreGState()
        }
    }

    private static func drawPlaceholder(in size: CGSize, context: CGContext) {
        let inset = min(size.width, size.height) * 0.15
        let rect = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
        context.setFillColor(CGColor(gray: 0.5, alpha: 0.2))
        context.fill(rect)
    }

    private static func drawAspectFit(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        context.draw(image, in: CGRect(origin: origin, size: drawSize))
    }
}
