import CoreGraphics
import Foundation

/// Builds a synthetic, top-down RGBA8 `CGImage` for tests: row 0 is the visual top of the
/// image, exactly as ImageIO decodes real photos, so pixel positions in test fixtures mean
/// what they say ("top-left", "bottom half", etc).
func makeTestImage(width: Int, height: Int, pixel: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = pixel(x, y)
            let offset = (y * width + x) * 4
            buffer[offset] = r
            buffer[offset + 1] = g
            buffer[offset + 2] = b
            buffer[offset + 3] = 255
        }
    }

    let provider = CGDataProvider(data: Data(buffer) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

struct RGB: Equatable, CustomStringConvertible {
    let r: UInt8, g: UInt8, b: UInt8
    var description: String { "rgb(\(r), \(g), \(b))" }
}

struct PixelBuffer {
    let buffer: [UInt8]
    let width: Int
    let height: Int

    subscript(x: Int, y: Int) -> RGB {
        let offset = (y * width + x) * 4
        return RGB(r: buffer[offset], g: buffer[offset + 1], b: buffer[offset + 2])
    }
}

/// Reads `image` back into a top-down RGBA8 buffer for pixel assertions — independent of
/// `ImageSplitter`'s own pixel access, so tests verify its output rather than its method.
func topDownPixels(of image: CGImage) -> PixelBuffer {
    let width = image.width
    let height = image.height

    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // No Cartesian flip needed: CGContext.draw(_:in:) already places a CGImage's
    // row-major, top-down data at buffer row 0 = visual top (see ImageSplitter.swift).
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let buffer = Array(UnsafeRawBufferPointer(start: context.data!, count: width * height * 4))
    return PixelBuffer(buffer: buffer, width: width, height: height)
}
