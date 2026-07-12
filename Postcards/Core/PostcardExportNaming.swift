import Foundation

/// Pure naming logic for a card's drag-out export (see `PostcardFileExport`): what filename
/// its raw, untouched stored bytes should be written to disk under when dropped into
/// Finder/Files.
enum PostcardExportNaming {
    /// Maps a card's stored `mimetype` to the extension its raw bytes actually decode as.
    /// Anything other than webP/PNG falls back to jpeg (the Go core's most common stored
    /// format) rather than failing outright on an unrecognized mimetype.
    static func fileExtension(forMimetype mimetype: String) -> String {
        switch mimetype.lowercased() {
        case "image/webp": return "webp"
        case "image/png": return "png"
        default: return "jpeg"
        }
    }

    /// The filename to export a card's stored bytes under: `filename` verbatim when it's
    /// already the compound `{name}.postcard.{ext}` (or bare `.postcard`) form — checked via
    /// `CloudItemAttributes.kind`, the same classifier iCloud sync already uses, rather than
    /// a second copy of that suffix logic here — falling back to constructing
    /// `{name}.postcard.{ext}` from `name` + `mimetype` when `filename` doesn't qualify (e.g.
    /// is empty, or missing the marker entirely).
    static func exportFilename(name: String, filename: String, mimetype: String) -> String {
        if CloudItemAttributes.kind(forFilename: filename) == .card {
            return filename
        }
        return "\(name).postcard.\(fileExtension(forMimetype: mimetype))"
    }
}
