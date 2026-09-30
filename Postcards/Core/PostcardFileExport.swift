import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Drag-out export of a card as a portable dotpostcard file: fetches the card's raw,
/// untouched stored bytes (combined front+back web-format image, XMP metadata embedded —
/// see `GoCore.image(for:)`) and hands them to the system as a `{name}.postcard.{ext}` file,
/// droppable into Finder/Files and importable elsewhere unchanged.
struct PostcardFileExport: Transferable {
    let reference: CardReference

    static var transferRepresentation: some TransferRepresentation {
        // `exportedContentType` is declared once at the type level — it can't vary
        // per-instance between the concrete image types a card might actually be
        // (webP/jpeg/png), since the exporting closure only runs once the type has already
        // been negotiated. `.image` is the common supertype all three conform to, so it's
        // used here; the exported temp file's own name (below, always ending in the card's
        // REAL extension) is what Finder/Files key off once the file actually lands on disk,
        // matching the "Postcard Image" alternate document type (public.jpeg/public.png/
        // org.webmproject.webp) already declared in project.yml.
        FileRepresentation(exportedContentType: .image) { export in
            let data = try await GoCore.shared.image(for: export.reference)
            let summary = export.reference.summary
            let filename = PostcardExportNaming.exportFilename(
                name: summary.name,
                filename: summary.filename,
                mimetype: summary.mimetype
            )

            // A unique subdirectory per export, so two simultaneous drags (or two drags of
            // differently-named cards in the same beat) never collide on the same temp path —
            // no cleanup here beyond that; it's the system temp directory.
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "PostcardExport-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appending(path: filename)
            try data.write(to: fileURL)
            return SentTransferredFile(fileURL)
        }
    }
}

extension View {
    /// Attaches `.draggable(...)` for a card's drag-out export (see `PostcardFileExport`).
    /// To offer it only some of the time, stop the view taking hits instead (as
    /// `CardDetailView` does while zoomed): adding and removing the modifier changes the
    /// view's identity, which cancels whatever gesture is in flight on it.
    func draggablePostcard(_ reference: CardReference) -> some View {
        draggable(PostcardFileExport(reference: reference))
    }
}
