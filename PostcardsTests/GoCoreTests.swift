import XCTest
import CoreGraphics
import ImageIO

/// Direct, end-to-end tests against the Go core (no @testable import — see README), using
/// the bundled fixture collection copied into the test bundle as a resource.
final class GoCoreTests: XCTestCase {
    private func fixturePath() throws -> String {
        try XCTUnwrap(
            Bundle(for: GoCoreTests.self).url(forResource: "fixture", withExtension: "postcards"),
            "fixture.postcards must be a test bundle resource"
        ).path
    }

    func testBundledFixtureTitleReadsSampleCollectionThroughGoCore() async throws {
        let title = try await GoCore.shared.title(ofCollectionAt: try fixturePath())
        XCTAssertEqual(title, "Sample Collection")
    }

    /// Regression test for the grid's "no plate behind transparent cards" requirement: a
    /// transparent card's thumbnail must actually be a PNG carrying real alpha, not a JPEG
    /// with the transparency flattened to a solid colour.
    func testTransparentCardThumbnailIsPNGWithTransparentCorners() async throws {
        let data = try await GoCore.shared.thumbnail(forCard: "transparency-card", inCollectionAt: try fixturePath())

        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(data.prefix(8)), pngSignature, "must stay PNG, not fall back to JPEG, to preserve alpha")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(topLeftAlpha(of: image), 0, "corner pixel should be fully transparent, not matted to black/white")
    }

    private func topLeftAlpha(of image: CGImage) -> UInt8 {
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
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let buffer = context.data!.assumingMemoryBound(to: UInt8.self)
        return buffer[3]
    }

    // MARK: - Writes

    /// A fresh temp directory per test, cleaned up afterwards, standing in for the app's
    /// own container the way `LibraryModelImportTests` does for the import pipeline.
    private func makeTempCollectionPath(_ filename: String = "roundtrip.postcards") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "GoCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appending(path: filename)
    }

    func testWriteRoundTripCreateAddListRemove() async throws {
        let collectionPath = try makeTempCollectionPath().path

        try await GoCore.shared.createCollection(at: collectionPath, title: "Round Trip")
        let title = try await GoCore.shared.title(ofCollectionAt: collectionPath)
        XCTAssertEqual(title, "Round Trip")
        let emptyCards = try await GoCore.shared.cardSummaries(inCollectionAt: collectionPath)
        XCTAssertTrue(emptyCards.isEmpty)

        // Borrow a real card's bytes from the bundled fixture rather than hand-rolling one.
        let fixturePath = try fixturePath()
        let fixtureCards = try await GoCore.shared.cardSummaries(inCollectionAt: fixturePath)
        let sourceCard = try XCTUnwrap(fixtureCards.first)
        let data = try await GoCore.shared.image(forCard: sourceCard.name, inCollectionAt: fixturePath)

        let added = try await GoCore.shared.addCard(filename: sourceCard.filename, data: data, toCollectionAt: collectionPath)
        XCTAssertEqual(added.name, sourceCard.name)
        // Invalidation must have happened: this reads through the same cached handle the
        // create/list calls above already opened.
        let cardsAfterAdd = try await GoCore.shared.cardSummaries(inCollectionAt: collectionPath)
        XCTAssertEqual(cardsAfterAdd.map(\.name), [sourceCard.name])

        try await GoCore.shared.removeCard(named: sourceCard.name, fromCollectionAt: collectionPath)
        let cardsAfterRemove = try await GoCore.shared.cardSummaries(inCollectionAt: collectionPath)
        XCTAssertTrue(cardsAfterRemove.isEmpty)
    }

    /// Regression test for `GoCore.moveCard`'s copy-then-remove ordering: a failure adding
    /// to the target (a path whose parent directory doesn't exist) must never remove the
    /// card from the source collection first.
    func testMoveCardFailurePathLeavesSourceCollectionIntact() async throws {
        let sourcePath = try makeTempCollectionPath("source.postcards").path
        try await GoCore.shared.createCollection(at: sourcePath)

        let fixturePath = try fixturePath()
        let fixtureCards = try await GoCore.shared.cardSummaries(inCollectionAt: fixturePath)
        let sourceCard = try XCTUnwrap(fixtureCards.first)
        let data = try await GoCore.shared.image(forCard: sourceCard.name, inCollectionAt: fixturePath)
        try await GoCore.shared.addCard(filename: sourceCard.filename, data: data, toCollectionAt: sourcePath)

        let badTargetPath = "/nonexistent-\(UUID().uuidString)/target.postcards"

        do {
            try await GoCore.shared.moveCard(named: sourceCard.name, filename: sourceCard.filename, from: sourcePath, to: badTargetPath)
            XCTFail("expected moving to a bad target path to fail")
        } catch {
            // Expected.
        }

        let cardsAfterFailedMove = try await GoCore.shared.cardSummaries(inCollectionAt: sourcePath)
        XCTAssertEqual(cardsAfterFailedMove.map(\.name), [sourceCard.name], "a failed move must leave the source untouched")
    }
}
