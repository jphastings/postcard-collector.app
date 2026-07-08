import CoreGraphics
import Foundation
import ImageIO

/// Native (Go-free) extraction of the two facts a bare `.postcard`/`.postcard.<ext>` file
/// needs before its combined image is split: whether it's a postcard at all, and the true
/// pixel size of its front side. Reads the embedded XMP packet as plain text — the same
/// bytes for WebP, JPEG, and PNG alike — rather than linking the Go core.
enum CardFileXMP {
    private static let openTag = "<x:xmpmeta"
    private static let closeTag = "</x:xmpmeta>"

    /// The value of the embedded `Postcard:Flip` XMP field, or `nil` if none is present.
    /// Presence of this field is the canonical "this is a postcard" marker — nothing else
    /// distinguishes a bare `.postcard.jpeg` from an ordinary photo.
    static func flip(in data: Data) -> Flip? {
        guard let packet = xmpPacketText(in: data) else { return nil }
        let value = elementValue(tag: "Postcard:Flip", in: packet) ?? attributeValue(name: "Postcard:Flip", in: packet)
        guard let value else { return nil }
        return Flip(rawValue: value)
    }

    /// The front side's true pixel size, read from the image header only (no pixel
    /// decode). The stored file is the combined, stacked front+back image; when `flip`
    /// isn't `.none` a back is stacked beneath the front, so the front's height is half
    /// the whole image's height.
    static func frontPixelSize(data: Data, flip: Flip) -> CGSize? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return CGSize(width: width, height: flip == .none ? height : height / 2)
    }

    // MARK: - XMP packet

    /// Finds the `<x:xmpmeta>...</x:xmpmeta>` packet within the raw file bytes and decodes
    /// it as UTF-8 text (XMP is always plain XML, embedded verbatim in WebP/JPEG/PNG).
    private static func xmpPacketText(in data: Data) -> String? {
        guard
            let openTagData = openTag.data(using: .utf8),
            let closeTagData = closeTag.data(using: .utf8),
            let openRange = data.range(of: openTagData),
            let closeRange = data.range(of: closeTagData, in: openRange.upperBound..<data.endIndex)
        else {
            return nil
        }
        return String(data: data.subdata(in: openRange.lowerBound..<closeRange.upperBound), encoding: .utf8)
    }

    /// Matches the element form Go's `encoding/xml` emits, e.g. `<Postcard:Flip>book</Postcard:Flip>`.
    private static func elementValue(tag: String, in packet: String) -> String? {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard
            let openRange = packet.range(of: open),
            let closeRange = packet.range(of: close, range: openRange.upperBound..<packet.endIndex)
        else {
            return nil
        }
        return String(packet[openRange.upperBound..<closeRange.lowerBound])
    }

    /// Falls back to the attribute form, e.g. `Postcard:Flip="book"`.
    private static func attributeValue(name: String, in packet: String) -> String? {
        let needle = "\(name)=\""
        guard let start = packet.range(of: needle) else { return nil }
        guard let end = packet.range(of: "\"", range: start.upperBound..<packet.endIndex) else { return nil }
        return String(packet[start.upperBound..<end.lowerBound])
    }
}
