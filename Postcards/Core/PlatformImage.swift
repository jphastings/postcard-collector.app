import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #elseif os(macOS)
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// Wraps a decoded `CGImage` (e.g. `ImageSplitter`'s output) as a `PlatformImage`,
    /// bridging `UIImage`/`NSImage`'s differing initializers. Used for bare `.postcard.*`
    /// files' grid thumbnails, which — unlike collection cards — have no pre-generated
    /// thumbnail from the Go core and are derived from the full image instead.
    static func from(cgImage: CGImage) -> PlatformImage {
        #if os(iOS)
        return PlatformImage(cgImage: cgImage)
        #elseif os(macOS)
        return PlatformImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}
