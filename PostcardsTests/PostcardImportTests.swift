import CoreGraphics
import Foundation
import XCTest

/// Pure, Go-free coverage of `PostcardImport.swift`'s classification, regex, rational-string
/// parsing, and canonical-metadata decoding — no `GoCore` involved (see
/// `CreatePostcardIntegrationTests` for the real-Go-core round trip through
/// `CreatePostcardModel.resolveImport(urls:)`/`prefill(_:)`).
final class PostcardImportTests: XCTestCase {
    // MARK: - DroppedKind.classify / compiled-postcard filenames

    func testCompiledPostcardFilenamesAreRecognised() {
        for name in ["card.postcard", "card.postcard.jpg", "card.postcard.jpeg", "card.postcard.webp", "card.postcard.png", "CARD.POSTCARD.JPG"] {
            XCTAssertTrue(DroppedKind.isCompiledPostcardFilename(name), name)
        }
    }

    func testNonCompiledPostcardFilenamesAreRejected() {
        for name in ["card.jpg", "card-front.jpg", "card-meta.yaml", "postcard.jpg", "card.postcards"] {
            XCTAssertFalse(DroppedKind.isCompiledPostcardFilename(name), name)
        }
    }

    func testCompiledPostcardNameStripsFromPostcardOnward() {
        XCTAssertEqual(DroppedKind.compiledPostcardName(fromFilename: "harbor.postcard.jpg"), "harbor")
        XCTAssertEqual(DroppedKind.compiledPostcardName(fromFilename: "harbor.postcard"), "harbor")
    }

    func testClassifyRecognisesCompiledPostcardByFilenameAlone() {
        XCTAssertEqual(DroppedKind.classify(filename: "harbor.postcard.jpg", data: Data()), .compiledPostcard)
    }

    func testClassifyRecognisesComponentPieceByFilename() {
        XCTAssertEqual(DroppedKind.classify(filename: "harbor-front.png", data: Data()), .componentPiece(ComponentStem(name: "harbor", role: .front)))
    }

    func testClassifyFallsBackToPlainImageForOrdinaryFilenames() {
        XCTAssertEqual(DroppedKind.classify(filename: "IMG_1234.jpg", data: Data("not xmp".utf8)), .plainImage)
    }

    func testClassifySniffsXMPWhenFilenameDoesNotMatch() throws {
        let reader = try fixtureReader()
        let summary = try XCTUnwrap(reader.cardSummaries().first)
        let data = try reader.imageData(name: summary.name)

        // A compiled card's bytes, under a filename that looks like an ordinary scan.
        XCTAssertEqual(DroppedKind.classify(filename: "IMG_1234.jpg", data: data), .compiledPostcard)
    }

    // MARK: - ComponentStem.parse

    func testComponentStemParsesEveryRole() {
        XCTAssertEqual(ComponentStem.parse(filename: "trip-front.png"), ComponentStem(name: "trip", role: .front))
        XCTAssertEqual(ComponentStem.parse(filename: "trip-back.jpg"), ComponentStem(name: "trip", role: .back))
        XCTAssertEqual(ComponentStem.parse(filename: "trip-only.jpeg"), ComponentStem(name: "trip", role: .only))
        XCTAssertEqual(ComponentStem.parse(filename: "trip-front.webp"), ComponentStem(name: "trip", role: .front))
        XCTAssertEqual(ComponentStem.parse(filename: "trip-front.tif"), ComponentStem(name: "trip", role: .front))
        XCTAssertEqual(ComponentStem.parse(filename: "trip-front.tiff"), ComponentStem(name: "trip", role: .front))
        XCTAssertEqual(ComponentStem.parse(filename: "trip-meta.yaml"), ComponentStem(name: "trip", role: .meta(.yaml)))
        XCTAssertEqual(ComponentStem.parse(filename: "trip-meta.yml"), ComponentStem(name: "trip", role: .meta(.yaml)))
        XCTAssertEqual(ComponentStem.parse(filename: "trip-meta.json"), ComponentStem(name: "trip", role: .meta(.json)))
    }

    func testComponentStemIsCaseInsensitive() {
        XCTAssertEqual(ComponentStem.parse(filename: "trip-FRONT.PNG"), ComponentStem(name: "trip", role: .front))
    }

    func testComponentStemPreservesHyphenatedNames() {
        XCTAssertEqual(ComponentStem.parse(filename: "my-summer-trip-front.png"), ComponentStem(name: "my-summer-trip", role: .front))
    }

    func testComponentStemRejectsNonMatchingFilenames() {
        for name in ["trip.png", "trip-side.png", "trip-meta.txt", "trip-front.gif", "trip-meta"] {
            XCTAssertNil(ComponentStem.parse(filename: name), name)
        }
    }

    // MARK: - GoRationalString

    func testGoRationalStringParsesFraction() {
        XCTAssertEqual(GoRationalString.parse("74/5") ?? 0, 14.8, accuracy: 0.0001)
    }

    func testGoRationalStringParsesBareInteger() {
        XCTAssertEqual(GoRationalString.parse("15") ?? 0, 15, accuracy: 0.0001)
    }

    func testGoRationalStringParsesDecimal() {
        XCTAssertEqual(GoRationalString.parse("15.5") ?? 0, 15.5, accuracy: 0.0001)
    }

    func testGoRationalStringRejectsGarbage() {
        XCTAssertNil(GoRationalString.parse("not-a-number"))
        XCTAssertNil(GoRationalString.parse("1/0"))
    }

    // MARK: - ImportedMetadata decoding

    func testImportedMetadataDecodesPolygonSecretAsBoundingBox() throws {
        let json = Data(#"""
        {
            "location": {}, "flip": "none", "sender": {}, "recipient": {},
            "front": { "secrets": [{ "type": "polygon", "prehidden": true, "points": [[0.1, 0.2], [0.4, 0.2], [0.4, 0.5], [0.1, 0.5]] }] },
            "back": {}, "context": { "author": {} },
            "physical": { "frontSize": { "pxW": 600, "pxH": 400 } }
        }
        """#.utf8)

        let imported = try ImportedMetadata(json: json)
        let secret = try XCTUnwrap(imported.frontSecrets.first)
        XCTAssertEqual(secret.prehidden, true)
        assertRect(secret.rect, CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3))
    }

    func testImportedMetadataDecodesBoxSecret() throws {
        let json = Data(#"""
        {
            "location": {}, "flip": "none", "sender": {}, "recipient": {},
            "front": {}, "back": { "secrets": [{ "type": "box", "prehidden": false, "left": 0.2, "top": 0.3, "width": 0.1, "height": 0.15 }] },
            "context": { "author": {} }
        }
        """#.utf8)

        let imported = try ImportedMetadata(json: json)
        let secret = try XCTUnwrap(imported.backSecrets.first)
        XCTAssertEqual(secret.prehidden, false)
        XCTAssertEqual(secret.rect, CGRect(x: 0.2, y: 0.3, width: 0.1, height: 0.15))
    }

    func testImportedMetadataDecodesRationalPhysicalSize() throws {
        let json = Data(#"""
        {
            "location": {}, "flip": "none", "sender": {}, "recipient": {},
            "front": {}, "back": {}, "context": { "author": {} },
            "physical": { "frontSize": { "cmW": "74/5", "cmH": "15", "pxW": 600, "pxH": 400 }, "thicknessMM": 0.5, "cardColor": "#AABBCC" }
        }
        """#.utf8)

        let imported = try ImportedMetadata(json: json)
        let physical = try XCTUnwrap(imported.physical)
        XCTAssertEqual(physical.cmWidth ?? 0, 14.8, accuracy: 0.0001)
        XCTAssertEqual(physical.cmHeight ?? 0, 15, accuracy: 0.0001)
        XCTAssertEqual(physical.thicknessMM, 0.5)
        XCTAssertEqual(physical.cardColor, "#AABBCC")
    }

    func testImportedMetadataDecodesDecimalPhysicalSize() throws {
        let json = Data(#"""
        {
            "location": {}, "flip": "none", "sender": {}, "recipient": {},
            "front": {}, "back": {}, "context": { "author": {} },
            "physical": { "frontSize": { "cmW": "10.5", "cmH": "14.8", "pxW": 600, "pxH": 400 } }
        }
        """#.utf8)

        let imported = try ImportedMetadata(json: json)
        let physical = try XCTUnwrap(imported.physical)
        XCTAssertEqual(physical.cmWidth ?? 0, 10.5, accuracy: 0.0001)
        XCTAssertEqual(physical.cmHeight ?? 0, 14.8, accuracy: 0.0001)
    }

    func testImportedMetadataStillDecodesTheFieldsPostcardMetadataCovers() throws {
        let json = Data(#"""
        {
            "locale": "fr-FR", "location": { "name": "Paris" }, "flip": "book",
            "sender": { "name": "Alice" }, "recipient": { "name": "Bob" },
            "front": { "description": "A view" }, "back": {}, "context": { "author": {} }
        }
        """#.utf8)

        let imported = try ImportedMetadata(json: json)
        XCTAssertEqual(imported.metadata.locale, "fr-FR")
        XCTAssertEqual(imported.metadata.location.name, "Paris")
        XCTAssertEqual(imported.metadata.flip, .book)
        XCTAssertEqual(imported.metadata.sender.name, "Alice")
        XCTAssertEqual(imported.metadata.front.description, "A view")
    }

    // MARK: - Sibling discovery (macOS only — see CLAUDE.md on sandboxing)

    #if os(macOS)
    func testSiblingDiscoveryFindsEveryPieceOfTheSameStem() throws {
        let directory = try makeTempDirectory()
        for filename in ["trip-front.png", "trip-back.png", "trip-meta.yaml", "other-front.png", "not-a-component.jpg"] {
            FileManager.default.createFile(atPath: directory.appending(path: filename).path, contents: Data())
        }

        let siblings = ComponentBundleDiscovery.siblings(ofName: "trip", in: directory)
        let names = Set(siblings.map(\.lastPathComponent))
        XCTAssertEqual(names, ["trip-front.png", "trip-back.png", "trip-meta.yaml"])
    }

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PostcardImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    // MARK: - ComponentProvenance capture during resolveImport (no meta, or a JSON meta — no
    // Go core involved; see `CreatePostcardIntegrationTests` for the YAML-sidecar cases, which
    // decode through the real Go core)

    func testResolveImportCapturesComponentProvenanceWithoutASidecar() async throws {
        let directory = try makeTempDirectory()
        let frontURL = directory.appending(path: "trip-front.png")
        try Data([0x01]).write(to: frontURL)
        let backURL = directory.appending(path: "trip-back.png")
        try Data([0x02]).write(to: backURL)

        guard case .bundle(let bundle) = try await CreatePostcardModel.resolveImport(urls: [frontURL, backURL]) else {
            return XCTFail("a component front+back drop must resolve to a bundle")
        }
        let provenance = try XCTUnwrap(bundle.componentProvenance)

        // `deletingLastPathComponent()` returns a directory URL with a trailing slash, which
        // `directory` itself (built via `appending(path:)`) doesn't have — `.path` normalizes
        // that away for comparison.
        XCTAssertEqual(provenance.directory.path, directory.path)
        XCTAssertEqual(provenance.stem, "trip")
        XCTAssertNil(provenance.existingYAMLMetaURL, "no sidecar was found")
        XCTAssertEqual(provenance.sidecarURL, directory.appending(path: "trip-meta.yaml"), "defaults to a fresh .yaml sidecar")
    }

    func testResolveImportDefaultsToFreshYAMLWhenExistingSidecarIsJSON() async throws {
        let directory = try makeTempDirectory()
        let frontURL = directory.appending(path: "trip-front.png")
        try Data([0x01]).write(to: frontURL)
        let jsonMetaURL = directory.appending(path: "trip-meta.json")
        let json = #"{"location":{},"flip":"none","sender":{},"recipient":{},"front":{},"back":{},"context":{"author":{}}}"#
        try json.write(to: jsonMetaURL, atomically: true, encoding: .utf8)

        guard case .bundle(let bundle) = try await CreatePostcardModel.resolveImport(urls: [frontURL, jsonMetaURL]) else {
            return XCTFail("a component front + JSON meta drop must resolve to a bundle")
        }
        let provenance = try XCTUnwrap(bundle.componentProvenance)

        XCTAssertNil(provenance.existingYAMLMetaURL, "the Go binding only emits YAML, so a JSON sidecar can't be overwritten in place")
        XCTAssertEqual(provenance.sidecarURL, directory.appending(path: "trip-meta.yaml"))
    }
    #endif

    // MARK: - ComponentProvenance.sidecarURL (pure — no filesystem, no Go core)

    func testSidecarURLUsesExistingYAMLMetaURLWhenPresent() {
        let directory = URL(fileURLWithPath: "/tmp/somewhere")
        let existing = directory.appending(path: "trip-meta.yml")
        let provenance = ComponentProvenance(directory: directory, stem: "trip", existingYAMLMetaURL: existing)

        XCTAssertEqual(provenance.sidecarURL, existing, "an existing .yml sidecar's exact path is reused, not switched to .yaml")
    }

    func testSidecarURLDefaultsToStemMetaYAMLWhenNoExistingSidecar() {
        let directory = URL(fileURLWithPath: "/tmp/somewhere")
        let provenance = ComponentProvenance(directory: directory, stem: "trip", existingYAMLMetaURL: nil)

        XCTAssertEqual(provenance.sidecarURL, directory.appending(path: "trip-meta.yaml"))
    }

    /// Component-wise `CGRect` comparison — a bounding box built from summed/subtracted
    /// doubles won't hit `CGRect.==`'s exact equality, e.g. `0.4 - 0.1` lands on
    /// `0.30000000000000004`.
    private func assertRect(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.0001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Fixture

    private func fixtureReader() throws -> CollectionReader {
        let path = try XCTUnwrap(
            Bundle(for: PostcardImportTests.self).url(forResource: "fixture", withExtension: "postcards"),
            "fixture.postcards must be a test bundle resource"
        ).path
        return try CollectionReader(path: path)
    }
}
