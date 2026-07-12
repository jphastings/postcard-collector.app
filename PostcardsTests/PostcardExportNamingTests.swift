import XCTest

/// Covers `PostcardExportNaming`'s pure logic: mimetype→extension mapping, and the
/// filename-verbatim-vs-fallback decision for a card's drag-out export.
final class PostcardExportNamingTests: XCTestCase {
    func testMimetypeMapsToItsExtension() {
        XCTAssertEqual(PostcardExportNaming.fileExtension(forMimetype: "image/webp"), "webp")
        XCTAssertEqual(PostcardExportNaming.fileExtension(forMimetype: "image/png"), "png")
        XCTAssertEqual(PostcardExportNaming.fileExtension(forMimetype: "image/jpeg"), "jpeg")
    }

    func testUnrecognizedMimetypeFallsBackToJpeg() {
        XCTAssertEqual(PostcardExportNaming.fileExtension(forMimetype: "application/octet-stream"), "jpeg")
    }

    func testExtensionMappingIsCaseInsensitive() {
        XCTAssertEqual(PostcardExportNaming.fileExtension(forMimetype: "IMAGE/WEBP"), "webp")
    }

    func testUsesTheStoredFilenameVerbatimWhenItsAlreadyCompound() {
        let name = PostcardExportNaming.exportFilename(
            name: "kyoto-trip", filename: "kyoto-trip.postcard.jpeg", mimetype: "image/jpeg"
        )
        XCTAssertEqual(name, "kyoto-trip.postcard.jpeg")
    }

    func testUsesTheStoredFilenameVerbatimForTheBareSuffixToo() {
        let name = PostcardExportNaming.exportFilename(
            name: "kyoto-trip", filename: "kyoto-trip.postcard", mimetype: "image/jpeg"
        )
        XCTAssertEqual(name, "kyoto-trip.postcard")
    }

    func testFallsBackToConstructingAFilenameWhenTheStoredOneDoesntQualify() {
        let name = PostcardExportNaming.exportFilename(
            name: "kyoto-trip", filename: "", mimetype: "image/webp"
        )
        XCTAssertEqual(name, "kyoto-trip.postcard.webp")
    }

    func testFallsBackWhenTheStoredFilenameIsAnUnrelatedName() {
        let name = PostcardExportNaming.exportFilename(
            name: "kyoto-trip", filename: "scan0001.jpg", mimetype: "image/png"
        )
        XCTAssertEqual(name, "kyoto-trip.postcard.png")
    }
}
