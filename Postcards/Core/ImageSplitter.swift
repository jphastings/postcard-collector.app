import CoreGraphics
import Foundation
import ImageIO

enum ImageSplitterError: Error {
    case couldNotDecode
    case couldNotCrop
    case couldNotRenderPixels
}

/// The front and (if present) back images extracted from a card's stored, combined
/// web-format file. `back` is already rotated so it reads upright, whatever the flip type.
struct SplitPostcardImage {
    let front: CGImage
    let back: CGImage?
}

/// Splits a postcard's combined (stacked front-then-back) image, as stored by the `web`
/// format, back into its two sides. Go never decodes pixels at app runtime (see
/// `formats/web/decode.go`) — this is the Swift-side equivalent of that function, run
/// natively via ImageIO/CoreGraphics instead.
enum ImageSplitter {
    /// Decodes `data` (the raw bytes from `GoCore.image(forCard:...)`) and splits it
    /// according to `flip`. For `.none` the whole image is the front, with no back.
    static func split(data: Data, flip: Flip) throws -> SplitPostcardImage {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let combined = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageSplitterError.couldNotDecode
        }
        return try split(combined, flip: flip)
    }

    /// As `split(data:flip:)`, but decodes at a bounded size via ImageIO's thumbnail path
    /// instead of the image's full resolution — for callers (grids, previews) that don't
    /// need every pixel and want to bound decode time/memory. Downsampling only affects
    /// sharpness; it never touches the soft alpha edge matting postcards rely on for their
    /// physical shape, so no masking/edge processing is added here.
    static func split(data: Data, flip: Flip, maxPixelSize: Int) throws -> SplitPostcardImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw ImageSplitterError.couldNotDecode
        }
        return try split(thumbnail, flip: flip)
    }

    /// As `split(data:flip:)`, for an already-decoded combined image (used directly by tests).
    static func split(_ combined: CGImage, flip: Flip) throws -> SplitPostcardImage {
        guard flip != .none else {
            return SplitPostcardImage(front: combined, back: nil)
        }

        let width = combined.width
        let sideHeight = combined.height / 2

        // CGImage's own coordinate space (both for `cropping(to:)` and for the raw pixel
        // buffers this file reads/writes elsewhere) is row-major from the top, matching
        // the byte layout Go decodes: (0,0) is the top-left corner, y grows downwards.
        // The front is always the top half; the (pre-rotation) back is the bottom half.
        guard
            let front = combined.cropping(to: CGRect(x: 0, y: 0, width: width, height: sideHeight)),
            let rawBack = combined.cropping(to: CGRect(x: 0, y: sideHeight, width: width, height: sideHeight))
        else {
            throw ImageSplitterError.couldNotCrop
        }

        // Hand flips store the back pre-rotated (see formats/web/encode.go's
        // rotateForWeb), so it must be un-rotated here to read upright:
        //
        //   encode: left-hand back  -> rotated 90° CCW before being stored
        //           right-hand back -> rotated 90° CW before being stored
        //   decode (formats/web/decode.go:56-61) undoes this with the *opposite*
        //           direction: left-hand -> rotate 90° CW; right-hand -> rotate 90° CCW.
        //
        // (Derived by tracing pixel index math in both rotateForWeb call sites — see
        // ImageSplitterTests for a corner-marker test that verifies the direction.)
        let back: CGImage
        switch flip {
        case .leftHand:
            back = try rotated90(rawBack, clockwise: true)
        case .rightHand:
            back = try rotated90(rawBack, clockwise: false)
        default:
            back = rawBack
        }

        return SplitPostcardImage(front: front, back: back)
    }

    // MARK: - Rotation

    /// Rotates `image` by 90°, by decoding it into a top-down RGBA8 buffer, permuting
    /// pixels with the same index math as Go's `rotateForWeb`, and re-wrapping the
    /// result as a CGImage. Implemented at the pixel level (rather than via
    /// `CGContext`'s Cartesian, y-up drawing model) so the rotation direction has no
    /// dependency on CoreGraphics' image-drawing flip conventions.
    static func rotated90(_ image: CGImage, clockwise: Bool) throws -> CGImage {
        let width = image.width
        let height = image.height
        let source = try topDownRGBA8(image)

        var destination = [UInt8](repeating: 0, count: source.count)
        let newWidth = height
        let newHeight = width

        source.withUnsafeBufferPointer { src in
            destination.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    for x in 0..<width {
                        let (nx, ny) = clockwise
                            ? (height - 1 - y, x)
                            : (y, width - 1 - x)
                        let srcOffset = (y * width + x) * 4
                        let dstOffset = (ny * newWidth + nx) * 4
                        dst[dstOffset] = src[srcOffset]
                        dst[dstOffset + 1] = src[srcOffset + 1]
                        dst[dstOffset + 2] = src[srcOffset + 2]
                        dst[dstOffset + 3] = src[srcOffset + 3]
                    }
                }
            }
        }

        return try makeImage(fromTopDownRGBA8: destination, width: newWidth, height: newHeight)
    }

    /// Decodes `image` into a top-down (row 0 = visual top), premultiplied RGBA8 buffer.
    private static func topDownRGBA8(_ image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height

        // Let CoreGraphics own the backing store (rather than handing it a pointer into
        // a Swift Array, whose lifetime/address isn't guaranteed to outlive this call).
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else {
            throw ImageSplitterError.couldNotRenderPixels
        }

        // `CGContext.draw(_:in:)` already places a CGImage's row-major, top-down pixel
        // data at buffer row 0 = visual top (verified empirically in ImageSplitterTests
        // with a corner-marker image) — no manual Cartesian flip is needed here.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // `data` points into `context`'s backing store, so `context` must outlive this read.
        // Without withExtendedLifetime, an optimized (Release) build is free to release
        // `context` right after `context.draw` above — freeing the store and making the copy
        // a use-after-free that only ever misbehaves in Release/archived builds.
        return withExtendedLifetime(context) {
            Array(UnsafeRawBufferPointer(start: data, count: width * height * 4))
        }
    }

    private static func makeImage(fromTopDownRGBA8 buffer: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageSplitterError.couldNotRenderPixels
        }

        buffer.withUnsafeBytes { raw in
            context.data?.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }

        guard let image = context.makeImage() else {
            throw ImageSplitterError.couldNotRenderPixels
        }
        return image
    }
}
