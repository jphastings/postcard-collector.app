import CoreGraphics
import Foundation
import ImageIO
import XCTest

@MainActor
final class CreatePostcardModelTests: XCTestCase {
    // MARK: - Fixture generation

    /// Writes a tiny in-memory image (no committed binaries needed) with `dpi` embedded via
    /// `kCGImagePropertyDPIWidth`/`DPIHeight`, or omitted entirely when `dpi` is `nil`.
    private func makeImageData(width: Int, height: Int, dpi: Double?, utType: String = "public.jpeg") -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, utType as CFString, 1, nil) else {
            XCTFail("couldn't create an image destination")
            return Data()
        }
        let image = makeTestImage(width: width, height: height) { _, _ in (180, 120, 60) }
        var properties: [CFString: Any] = [:]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return mutableData as Data
    }

    private func decodeJSONObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// Component-wise `CGRect` comparison — a bounding box built from summed/subtracted
    /// doubles (see `ImportedSecret.boundingBox(ofPoints:)`) won't hit `CGRect.==`'s exact
    /// equality, e.g. `0.4 - 0.1` lands on `0.30000000000000004`.
    private func assertRect(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat = 0.0001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - DPI -> cm math

    func testSuggestedCmSizeComputesFromPixelsAndDPI() {
        let probed = ProbedImage(data: Data(), pixelWidth: 2480, pixelHeight: 1748, dpiWidth: 300, dpiHeight: 300)
        XCTAssertEqual(probed.suggestedCmWidth ?? 0, 21.0, accuracy: 0.05)
        XCTAssertEqual(probed.suggestedCmHeight ?? 0, 14.8, accuracy: 0.05)
    }

    func testSuggestedCmSizeIsNilWithoutDPI() {
        let probed = ProbedImage(data: Data(), pixelWidth: 2480, pixelHeight: 1748, dpiWidth: nil, dpiHeight: nil)
        XCTAssertNil(probed.suggestedCmWidth)
        XCTAssertNil(probed.suggestedCmHeight)
    }

    // MARK: - Probing real image headers

    func testProbeReadsPixelSizeAndEmbeddedDPI() throws {
        let data = makeImageData(width: 300, height: 200, dpi: 150)
        let probed = try XCTUnwrap(ProbedImage.probe(data: data))

        XCTAssertEqual(probed.pixelWidth, 300)
        XCTAssertEqual(probed.pixelHeight, 200)
        XCTAssertEqual(probed.dpiWidth ?? 0, 150, accuracy: 1)
        XCTAssertEqual(probed.dpiHeight ?? 0, 150, accuracy: 1)
    }

    func testProbeHasNoDPIWhenTheSourceOmitsIt() throws {
        let data = makeImageData(width: 120, height: 80, dpi: nil, utType: "public.png")
        let probed = try XCTUnwrap(ProbedImage.probe(data: data))

        XCTAssertEqual(probed.pixelWidth, 120)
        XCTAssertNil(probed.dpiWidth)
        XCTAssertNil(probed.dpiHeight)
    }

    func testProbeReturnsNilForUnreadableData() {
        XCTAssertNil(ProbedImage.probe(data: Data([0x00, 0x01, 0x02])))
    }

    // MARK: - Name derivation

    func testDerivedNameStripsExtensionAndFrontOrOnlySuffix() {
        XCTAssertEqual(CreatePostcardModel.derivedName(fromFilename: "scan-front.tiff"), "scan")
        XCTAssertEqual(CreatePostcardModel.derivedName(fromFilename: "holiday-only.png"), "holiday")
        XCTAssertEqual(CreatePostcardModel.derivedName(fromFilename: "plain.jpeg"), "plain")
    }

    func testSettingFrontDerivesDefaultName() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 100, height: 80, dpi: nil), filename: "scan-front.tiff")
        XCTAssertEqual(model.name, "scan")
    }

    func testSettingFrontDoesNotOverwriteAUserEditedName() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 100, height: 80, dpi: nil), filename: "scan-front.tiff")
        model.name = "My Trip"

        try model.setFront(data: makeImageData(width: 90, height: 70, dpi: nil), filename: "holiday-only.png")

        XCTAssertEqual(model.name, "My Trip")
    }

    func testSettingFrontThrowsForUnreadableData() {
        let model = CreatePostcardModel()
        XCTAssertThrowsError(try model.setFront(data: Data([0xFF, 0x00]), filename: "bad.jpg"))
    }

    // MARK: - Dimension editing

    func testCmFieldsReseedFromEmbeddedDPIOnSettingFront() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: 100), filename: "front.jpg")

        XCTAssertEqual(model.cmWidthText, "5.1")
        XCTAssertEqual(model.cmHeightText, "2.5")
        XCTAssertFalse(model.dimensionsEdited)
    }

    func testCmFieldsAreEmptyWhenDPIIsMissing() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")

        XCTAssertEqual(model.cmWidthText, "")
        XCTAssertEqual(model.cmHeightText, "")
        XCTAssertFalse(model.dimensionsEdited)
    }

    func testEditingWidthRecomputesHeightPreservingPixelAspectRatio() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: 100), filename: "front.jpg")

        model.cmWidthText = "10.0"

        XCTAssertEqual(model.cmHeightText, "5.0")
        XCTAssertTrue(model.dimensionsEdited)
    }

    func testEditingHeightRecomputesWidthPreservingPixelAspectRatio() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: 100), filename: "front.jpg")

        model.cmHeightText = "10.0"

        XCTAssertEqual(model.cmWidthText, "20.0")
    }

    // MARK: - Dimensions chip

    func testDimensionsChipTextFormatsFromCmFields() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: 100), filename: "front.jpg")
        XCTAssertEqual(model.dimensionsChipText, "5.1 × 2.5 cm")
    }

    func testDimensionsChipTextIsNilWithoutAnySize() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        XCTAssertNil(model.dimensionsChipText)
    }

    func testDimensionsSourceFootnoteReflectsDPIThenCustomEdit() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: 100), filename: "front.jpg")
        XCTAssertEqual(model.dimensionsSourceFootnote, "From the scan's 100 dpi resolution.")

        model.cmWidthText = "10.0"
        XCTAssertEqual(model.dimensionsSourceFootnote, "Custom size — overrides the scan's embedded resolution.")
    }

    func testDimensionsSourceFootnoteWhenScanHasNoSizeInfo() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        XCTAssertEqual(model.dimensionsSourceFootnote, "No size info in the scan.")
    }

    // MARK: - ProbedImage identity

    func testProbedImageIdentityTravelsWithItsContentAcrossSwap() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        try model.setBack(data: makeImageData(width: 80, height: 60, dpi: nil, utType: "public.png"), filename: "back.png")
        let frontID = model.front?.id
        let backID = model.back?.id

        model.swapSides()

        XCTAssertEqual(model.back?.id, frontID, "swapping moves each image's identity along with its content")
        XCTAssertEqual(model.front?.id, backID)
    }

    // MARK: - Allowed flips

    func testAllowedFlipsForSquareFrontOffersAllFour() {
        let front = ProbedImage(data: Data(), pixelWidth: 1000, pixelHeight: 1002, dpiWidth: nil, dpiHeight: nil)
        let back = ProbedImage(data: Data(), pixelWidth: 500, pixelHeight: 900, dpiWidth: nil, dpiHeight: nil)
        XCTAssertEqual(CreatePostcardModel.allowedFlips(front: front, back: back), [.book, .calendar, .leftHand, .rightHand])
    }

    func testAllowedFlipsForMatchingOrientationsOffersBookAndCalendar() {
        let front = ProbedImage(data: Data(), pixelWidth: 900, pixelHeight: 600, dpiWidth: nil, dpiHeight: nil)
        let back = ProbedImage(data: Data(), pixelWidth: 800, pixelHeight: 500, dpiWidth: nil, dpiHeight: nil)
        XCTAssertEqual(CreatePostcardModel.allowedFlips(front: front, back: back), [.book, .calendar])
    }

    func testAllowedFlipsForDifferingOrientationsOffersHandFlips() {
        let front = ProbedImage(data: Data(), pixelWidth: 900, pixelHeight: 600, dpiWidth: nil, dpiHeight: nil)
        let back = ProbedImage(data: Data(), pixelWidth: 600, pixelHeight: 900, dpiWidth: nil, dpiHeight: nil)
        XCTAssertEqual(CreatePostcardModel.allowedFlips(front: front, back: back), [.leftHand, .rightHand])
    }

    func testAllowedFlipsWithNoBackIsNoneOnly() {
        let front = ProbedImage(data: Data(), pixelWidth: 900, pixelHeight: 600, dpiWidth: nil, dpiHeight: nil)
        XCTAssertEqual(CreatePostcardModel.allowedFlips(front: front, back: nil), [.none])
    }

    func testDefaultFlipIsFirstAllowedAndUpdatesWhenOrientationsChange() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 900, height: 600, dpi: nil, utType: "public.png"), filename: "front.png")
        try model.setBack(data: makeImageData(width: 800, height: 500, dpi: nil, utType: "public.png"), filename: "back.png")
        XCTAssertEqual(model.flip, .book, "same orientation -> first of book/calendar")

        try model.setBack(data: makeImageData(width: 500, height: 800, dpi: nil, utType: "public.png"), filename: "back2.png")
        XCTAssertEqual(model.flip, .leftHand, "now different orientation -> reset to first of left/right-hand")
    }

    func testClearingBackResetsFlipToNone() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 900, height: 600, dpi: nil, utType: "public.png"), filename: "front.png")
        try model.setBack(data: makeImageData(width: 800, height: 500, dpi: nil, utType: "public.png"), filename: "back.png")

        model.clearBack()

        XCTAssertEqual(model.flip, .none)
        XCTAssertTrue(model.backSecrets.isEmpty)
    }

    // MARK: - Physical size mismatch

    func testPhysicalMismatchWarningNilWhenSizesAgree() {
        let front = ProbedImage(data: Data(), pixelWidth: 1000, pixelHeight: 700, dpiWidth: 100, dpiHeight: 100)
        let back = ProbedImage(data: Data(), pixelWidth: 1000, pixelHeight: 700, dpiWidth: 100, dpiHeight: 100)
        XCTAssertNil(CreatePostcardModel.physicalMismatchWarning(front: front, back: back, flip: .book))
    }

    func testPhysicalMismatchWarningFiresPastOnePercent() {
        let front = ProbedImage(data: Data(), pixelWidth: 1000, pixelHeight: 700, dpiWidth: 100, dpiHeight: 100)
        let back = ProbedImage(data: Data(), pixelWidth: 1000, pixelHeight: 700, dpiWidth: 90, dpiHeight: 90)
        XCTAssertNotNil(CreatePostcardModel.physicalMismatchWarning(front: front, back: back, flip: .book))
    }

    func testPhysicalMismatchWarningSwapsWidthAndHeightForHeterorientedFlips() {
        // Front and back are the same physical size, just rotated — legal for a
        // left/right-hand flip, so comparing straight across would wrongly warn.
        let front = ProbedImage(data: Data(), pixelWidth: 1000, pixelHeight: 700, dpiWidth: 100, dpiHeight: 100)
        let back = ProbedImage(data: Data(), pixelWidth: 700, pixelHeight: 1000, dpiWidth: 100, dpiHeight: 100)

        XCTAssertNotNil(
            CreatePostcardModel.physicalMismatchWarning(front: front, back: back, flip: .book),
            "book flip compares straight across, so a rotated back should warn"
        )
        XCTAssertNil(
            CreatePostcardModel.physicalMismatchWarning(front: front, back: back, flip: .leftHand),
            "left-hand flip swaps width/height, so the rotated back matches"
        )
    }

    func testPhysicalMismatchWarningNilWhenEitherSideLacksDPI() {
        let front = ProbedImage(data: Data(), pixelWidth: 1000, pixelHeight: 700, dpiWidth: nil, dpiHeight: nil)
        let back = ProbedImage(data: Data(), pixelWidth: 1000, pixelHeight: 700, dpiWidth: 100, dpiHeight: 100)
        XCTAssertNil(CreatePostcardModel.physicalMismatchWarning(front: front, back: back, flip: .book))
    }

    // MARK: - Alt text nudge

    func testAltTextNudgeWhenFrontDescriptionEmpty() {
        let model = CreatePostcardModel()
        XCTAssertTrue(model.altTextNudge)
        model.frontDescription = "A view of the harbor"
        XCTAssertFalse(model.altTextNudge)
    }

    func testAltTextNudgeWhenBackPresentWithEmptyDescription() throws {
        let model = CreatePostcardModel()
        model.frontDescription = "Front"
        try model.setBack(data: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), filename: "back.png")

        XCTAssertFalse(model.altTextNudge, "back descriptions default to skipped, so an empty one doesn't nudge")

        model.backDescriptionSkipped = false
        XCTAssertTrue(model.altTextNudge, "once un-skipped, an empty back description does nudge")
        model.backDescription = "Back"
        XCTAssertFalse(model.altTextNudge)
    }

    func testAltTextNudgeRespectsAnExplicitSkip() {
        let model = CreatePostcardModel()
        XCTAssertTrue(model.altTextNudge, "empty and not skipped -> nudge")

        model.frontDescriptionSkipped = true
        XCTAssertFalse(model.altTextNudge, "an explicit skip is a conscious choice, not an oversight")
    }

    // MARK: - canCreate gating

    func testCanCreateGatesOnFrontImageAndNameButNotDestination() throws {
        let model = CreatePostcardModel()
        XCTAssertFalse(model.canCreate)
        XCTAssertTrue(model.blockingIssues.contains(.missingFrontImage))

        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        XCTAssertTrue(model.canCreate, "a nil destination is itself valid — \"Individual postcards\", not an unset choice")
        XCTAssertNil(model.destinationCollectionPath)

        model.destinationCollectionPath = "/tmp/whatever.postcards"
        XCTAssertTrue(model.canCreate)
    }

    func testCanCreateBlocksOnEmptyOrSlashContainingName() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        XCTAssertTrue(model.canCreate)

        model.name = ""
        XCTAssertTrue(model.blockingIssues.contains(.invalidName))

        model.name = "a/b"
        XCTAssertTrue(model.blockingIssues.contains(.invalidName))
    }

    // MARK: - metadataJSON()

    func testMetadataJSONOmitsPhysicalWhenNothingEdited() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: 100), filename: "front.jpg")
        model.name = "card"

        let object = try decodeJSONObject(try model.metadataJSON())
        XCTAssertNil(object["physical"])
    }

    func testMetadataJSONIncludesFrontSizeAsDecimalStringsWhenDimensionsEdited() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: 100), filename: "front.jpg")
        model.name = "card"
        model.cmWidthText = "14.8"

        let object = try decodeJSONObject(try model.metadataJSON())
        let physical = try XCTUnwrap(object["physical"] as? [String: Any])
        let frontSize = try XCTUnwrap(physical["frontSize"] as? [String: Any])

        XCTAssertEqual(frontSize["cmW"] as? String, "14.8")
        XCTAssertEqual(frontSize["cmH"] as? String, "7.4")
        XCTAssertNil(frontSize["pxW"], "a forced size must omit pxW/pxH")
        XCTAssertNil(physical["thicknessMM"], "untouched thickness must be omitted")
        XCTAssertNil(physical["cardColor"], "untouched card color must be omitted")
    }

    func testMetadataJSONIncludesThicknessAndColorOnlyWhenTouched() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        model.name = "card"
        model.thicknessMM = 0.6
        model.cardColorHex = "#FFFFFF"

        let object = try decodeJSONObject(try model.metadataJSON())
        let physical = try XCTUnwrap(object["physical"] as? [String: Any])

        XCTAssertEqual(physical["thicknessMM"] as? Double, 0.6)
        XCTAssertEqual(physical["cardColor"] as? String, "#FFFFFF")
        XCTAssertNil(physical["frontSize"], "dimensions weren't edited")
    }

    func testMetadataJSONThrowsForUnparsableEditedDimensions() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: 100), filename: "front.jpg")
        model.name = "card"
        model.cmWidthText = "not a number"

        XCTAssertThrowsError(try model.metadataJSON())
    }

    func testMetadataJSONOmitsSentOnWhenUnset() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        model.name = "card"

        let object = try decodeJSONObject(try model.metadataJSON())
        XCTAssertNil(object["sentOn"])
    }

    func testMetadataJSONIncludesSentOnAsYYYYMMDDWhenSet() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        model.name = "card"
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        model.sentOn = calendar.date(from: DateComponents(year: 2024, month: 5, day: 1))

        let object = try decodeJSONObject(try model.metadataJSON())
        XCTAssertEqual(object["sentOn"] as? String, "2024-05-01")
    }

    func testMetadataJSONFlipIsNoneWithNoBackImageRegardlessOfFlipState() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        model.name = "card"

        let object = try decodeJSONObject(try model.metadataJSON())
        XCTAssertEqual(object["flip"] as? String, "none")
    }

    func testMetadataJSONSerializesFrontSecretsAsNormalizedBoxes() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        model.name = "card"
        model.frontSecrets = [SecretRegion(rect: CGRect(x: 0.6, y: 0.3, width: 0.2, height: 0.08), prehidden: true)]

        let object = try decodeJSONObject(try model.metadataJSON())
        let front = try XCTUnwrap(object["front"] as? [String: Any])
        let secrets = try XCTUnwrap(front["secrets"] as? [[String: Any]])

        XCTAssertEqual(secrets.count, 1)
        XCTAssertEqual(secrets[0]["type"] as? String, "box")
        XCTAssertEqual(secrets[0]["prehidden"] as? Bool, true)
        XCTAssertEqual(secrets[0]["left"] as? Double ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertEqual(secrets[0]["top"] as? Double ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(secrets[0]["width"] as? Double ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(secrets[0]["height"] as? Double ?? 0, 0.08, accuracy: 0.0001)
    }

    func testMetadataJSONOmitsSecretsKeyWhenNoneAreSet() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        model.name = "card"

        let object = try decodeJSONObject(try model.metadataJSON())
        let front = try XCTUnwrap(object["front"] as? [String: Any])
        XCTAssertNil(front["secrets"])
    }

    /// Ties the write side to the app's own read side: whatever `metadataJSON()` produces
    /// must decode cleanly through the exact `PostcardMetadata` the rest of the app uses.
    func testMetadataJSONDecodesBackIntoPostcardMetadata() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        model.name = "card"
        model.locale = "en-GB"
        model.frontDescription = "A nice view"
        model.senderName = "Alice"

        let metadata = try JSONDecoder().decode(PostcardMetadata.self, from: Data(try model.metadataJSON().utf8))

        XCTAssertEqual(metadata.locale, "en-GB")
        XCTAssertEqual(metadata.front.description, "A nice view")
        XCTAssertEqual(metadata.sender.name, "Alice")
        XCTAssertEqual(metadata.flip, .none)
    }

    // MARK: - Skip flags & metadataJSON

    func testMetadataJSONOmitsASkippedDescriptionButPreservesItInTheModel() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        model.name = "card"
        model.frontDescription = "A nice view"
        model.frontDescriptionSkipped = true

        let object = try decodeJSONObject(try model.metadataJSON())
        let front = try XCTUnwrap(object["front"] as? [String: Any])
        XCTAssertNil(front["description"])
        XCTAssertEqual(model.frontDescription, "A nice view", "skipping omits it from the payload without clearing the model")
    }

    func testMetadataJSONOmitsASkippedTranscriptionButPreservesItInTheModel() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        model.name = "card"
        model.frontTranscription = "Dear Alice,"
        model.frontTranscriptionSkipped = true

        let object = try decodeJSONObject(try model.metadataJSON())
        let front = try XCTUnwrap(object["front"] as? [String: Any])
        let transcription = front["transcription"] as? [String: Any]
        XCTAssertNil(transcription?["text"], "skipping omits the transcription text from the payload")
        XCTAssertEqual(model.frontTranscription, "Dear Alice,")
    }

    func testMetadataJSONIncludesAnUnskippedTranscription() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        model.name = "card"
        model.frontTranscription = "Dear Alice,"
        model.frontTranscriptionSkipped = false

        let object = try decodeJSONObject(try model.metadataJSON())
        let front = try XCTUnwrap(object["front"] as? [String: Any])
        let transcription = try XCTUnwrap(front["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["text"] as? String, "Dear Alice,")
    }

    // MARK: - Wizard steps

    func testDescribeStepsIncludesBackStepsOnlyWhenABackImageExists() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), filename: "front.png")
        XCTAssertEqual(model.describeSteps, [.frontDescription, .frontTranscription])

        try model.setBack(data: makeImageData(width: 90, height: 70, dpi: nil, utType: "public.png"), filename: "back.png")
        XCTAssertEqual(model.describeSteps, [.frontDescription, .frontTranscription, .backTranscription, .backDescription])
    }

    // MARK: - addImage

    func testAddImageFillsFrontThenBackThenReplacesTheBack() throws {
        let model = CreatePostcardModel()
        try model.addImage(data: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), filename: "one.png")
        XCTAssertEqual(model.front?.pixelWidth, 100)
        XCTAssertNil(model.back)

        try model.addImage(data: makeImageData(width: 90, height: 70, dpi: nil, utType: "public.png"), filename: "two.png")
        XCTAssertEqual(model.back?.pixelWidth, 90)

        model.backSecrets = [SecretRegion(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
        try model.addImage(data: makeImageData(width: 50, height: 40, dpi: nil, utType: "public.png"), filename: "three.png")

        XCTAssertEqual(model.front?.pixelWidth, 100, "a third image replaces the back, not the front")
        XCTAssertEqual(model.back?.pixelWidth, 50)
        XCTAssertTrue(model.backSecrets.isEmpty, "replacing the back clears its stale secret regions")
    }

    // MARK: - clearFront

    func testClearFrontClearsOnlyTheFrontSlot() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), filename: "front.png")
        try model.setBack(data: makeImageData(width: 90, height: 70, dpi: nil, utType: "public.png"), filename: "back.png")

        model.clearFront()

        XCTAssertNil(model.front)
        XCTAssertEqual(model.back?.pixelWidth, 90)
    }

    // MARK: - swapSides

    func testSwapSidesExchangesImagesSecretsAndText() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        try model.setBack(data: makeImageData(width: 80, height: 60, dpi: nil, utType: "public.png"), filename: "back.png")
        model.frontSecrets = [SecretRegion(rect: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))]
        model.backSecrets = [SecretRegion(rect: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1))]
        model.frontDescription = "Front text"
        model.backDescription = "Back text"
        model.frontTranscription = "Front handwriting"
        model.backTranscription = "Back handwriting"

        model.swapSides()

        XCTAssertEqual(model.front?.pixelWidth, 80)
        XCTAssertEqual(model.back?.pixelWidth, 200)
        XCTAssertEqual(model.frontSecrets.first?.rect.minX ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(model.backSecrets.first?.rect.minX ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(model.frontDescription, "Back text")
        XCTAssertEqual(model.backDescription, "Front text")
        XCTAssertEqual(model.frontTranscription, "Back handwriting")
        XCTAssertEqual(model.backTranscription, "Front handwriting")
    }

    func testSwapSidesCarriesATouchedSkipFlagWithItsContentAndRederivesTheUntouchedOne() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        try model.setBack(data: makeImageData(width: 80, height: 60, dpi: nil, utType: "public.png"), filename: "back.png")

        model.frontDescriptionSkipped = true // an explicit, non-default choice for the front

        model.swapSides()

        XCTAssertTrue(model.backDescriptionSkipped, "the touched choice travels to wherever its content (the front description) ended up")
        XCTAssertFalse(model.frontDescriptionSkipped, "untouched by the user, the new front re-derives its own default rather than inheriting the old front's")
    }

    func testSwapSidesSwapsTwoTouchedSkipFlagsNormally() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")
        try model.setBack(data: makeImageData(width: 80, height: 60, dpi: nil, utType: "public.png"), filename: "back.png")

        model.frontTranscriptionSkipped = false // touched, non-default (default is true)
        model.backTranscriptionSkipped = true // touched, non-default (default is false)

        model.swapSides()

        XCTAssertTrue(model.frontTranscriptionSkipped, "both sides touched -> values swap like everything else")
        XCTAssertFalse(model.backTranscriptionSkipped)
    }

    func testSwapSidesWithOnlyAFrontIsANoOp() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "front.png")

        model.swapSides()

        XCTAssertEqual(model.front?.pixelWidth, 200)
        XCTAssertNil(model.back)
    }

    func testSwapSidesWithOnlyABackPromotesItToFront() throws {
        let model = CreatePostcardModel()
        try model.setBack(data: makeImageData(width: 200, height: 100, dpi: nil, utType: "public.png"), filename: "back.png")
        XCTAssertNil(model.front)

        model.swapSides()

        XCTAssertEqual(model.front?.pixelWidth, 200)
        XCTAssertNil(model.back)
    }

    // MARK: - reset()

    /// Mutates every corner of the model — images, secrets, all text fields, skip flags (and
    /// their touched-tracking), dimensions, name, thickness/color, destination, spotlight —
    /// so `testResetMatchesAFreshModel` below actually exercises `reset()` rather than
    /// trivially passing on an already-pristine model.
    private func heavilyMutatedModel() throws -> CreatePostcardModel {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 200, height: 100, dpi: 100), filename: "front.jpg")
        try model.setBack(data: makeImageData(width: 90, height: 180, dpi: 100), filename: "back.jpg")

        model.name = "My Trip"
        model.cmWidthText = "12.3"
        model.flip = model.allowedFlips.first ?? .none

        model.locale = "fr-FR"
        model.sentOn = Date()
        model.senderName = "Alice"
        model.senderURI = "urn:person:alice"
        model.recipientName = "Bob"
        model.recipientURI = "urn:person:bob"
        model.locationName = "Paris"
        model.locationLatitude = 48.8
        model.locationLongitude = 2.3
        model.locationCountryCode = "FRA"
        model.frontDescription = "A view"
        model.frontTranscription = "Dear Bob,"
        model.backDescription = "Another view"
        model.backTranscription = "Love, Alice"
        model.contextAuthorName = "Collector"
        model.contextAuthorURI = "urn:person:collector"
        model.contextDescription = "Found at a market"

        model.frontDescriptionSkipped = true
        model.frontTranscriptionSkipped = false
        model.backTranscriptionSkipped = true
        model.backDescriptionSkipped = false

        model.thicknessMM = 0.8
        model.cardColorHex = "#FFFFFF"
        model.removeBorder = true
        model.archival = true

        model.frontSecrets = [SecretRegion(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
        model.backSecrets = [SecretRegion(rect: CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1), prehidden: true)]

        model.destinationCollectionPath = "/tmp/somewhere.postcards"
        model.spotlightSide = .front

        return model
    }

    func testResetMatchesAFreshModel() throws {
        let model = try heavilyMutatedModel()
        let fresh = CreatePostcardModel()

        model.reset()

        XCTAssertNil(model.front)
        XCTAssertNil(model.back)
        XCTAssertEqual(model.name, fresh.name)
        XCTAssertEqual(model.cmWidthText, fresh.cmWidthText)
        XCTAssertEqual(model.cmHeightText, fresh.cmHeightText)
        XCTAssertEqual(model.dimensionsEdited, fresh.dimensionsEdited)
        XCTAssertEqual(model.flip, fresh.flip)
        XCTAssertEqual(model.locale, fresh.locale)
        XCTAssertEqual(model.sentOn, fresh.sentOn)
        XCTAssertEqual(model.senderName, fresh.senderName)
        XCTAssertEqual(model.senderURI, fresh.senderURI)
        XCTAssertEqual(model.recipientName, fresh.recipientName)
        XCTAssertEqual(model.recipientURI, fresh.recipientURI)
        XCTAssertEqual(model.locationName, fresh.locationName)
        XCTAssertEqual(model.locationLatitude, fresh.locationLatitude)
        XCTAssertEqual(model.locationLongitude, fresh.locationLongitude)
        XCTAssertEqual(model.locationCountryCode, fresh.locationCountryCode)
        XCTAssertEqual(model.frontDescription, fresh.frontDescription)
        XCTAssertEqual(model.frontTranscription, fresh.frontTranscription)
        XCTAssertEqual(model.backDescription, fresh.backDescription)
        XCTAssertEqual(model.backTranscription, fresh.backTranscription)
        XCTAssertEqual(model.contextAuthorName, fresh.contextAuthorName)
        XCTAssertEqual(model.contextAuthorURI, fresh.contextAuthorURI)
        XCTAssertEqual(model.contextDescription, fresh.contextDescription)
        XCTAssertEqual(model.frontDescriptionSkipped, fresh.frontDescriptionSkipped)
        XCTAssertEqual(model.frontTranscriptionSkipped, fresh.frontTranscriptionSkipped)
        XCTAssertEqual(model.backTranscriptionSkipped, fresh.backTranscriptionSkipped)
        XCTAssertEqual(model.backDescriptionSkipped, fresh.backDescriptionSkipped)
        XCTAssertEqual(model.thicknessMM, fresh.thicknessMM)
        XCTAssertEqual(model.thicknessEdited, fresh.thicknessEdited)
        XCTAssertEqual(model.cardColorHex, fresh.cardColorHex)
        XCTAssertEqual(model.cardColorEdited, fresh.cardColorEdited)
        XCTAssertEqual(model.removeBorder, fresh.removeBorder)
        XCTAssertEqual(model.archival, fresh.archival)
        XCTAssertEqual(model.frontSecrets, fresh.frontSecrets)
        XCTAssertEqual(model.backSecrets, fresh.backSecrets)
        XCTAssertEqual(model.destinationCollectionPath, fresh.destinationCollectionPath)
        XCTAssertEqual(model.spotlightSide, fresh.spotlightSide)
        XCTAssertEqual(model.canCreate, fresh.canCreate)

        XCTAssertEqual(try model.metadataJSON(), try fresh.metadataJSON())
    }

    /// After a reset, re-touching a field must behave exactly like it would on a genuinely
    /// fresh model — proof that `reset()` clears the touched-tracking flags, not just the
    /// visible values they gate (see the skip flags' and `nameEdited`'s doc comments).
    func testResetClearsTouchedTrackingNotJustValues() throws {
        let model = try heavilyMutatedModel()

        model.reset()
        try model.setFront(data: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), filename: "scan-front.tiff")

        XCTAssertEqual(model.name, "scan", "name derivation must work again post-reset, proving nameEdited was cleared")
    }

    // MARK: - isPristine

    func testFreshModelIsPristine() {
        XCTAssertTrue(CreatePostcardModel().isPristine)
    }

    func testModelWithAFrontImageIsNotPristine() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), filename: "front.png")
        XCTAssertFalse(model.isPristine)
    }

    func testModelWithAnyTouchedTextFieldIsNotPristine() {
        let model = CreatePostcardModel()
        model.senderName = "Alice"
        XCTAssertFalse(model.isPristine)
    }

    func testPreselectedDestinationAloneDoesNotBreakPristine() {
        let model = CreatePostcardModel()
        model.destinationCollectionPath = "/tmp/some.postcards"
        XCTAssertTrue(model.isPristine, "a form-preselected destination isn't postcard content")
    }

    func testSpotlightSideAloneDoesNotBreakPristine() {
        let model = CreatePostcardModel()
        model.spotlightSide = .front
        XCTAssertTrue(model.isPristine, "ephemeral wizard focus isn't postcard content")
    }

    // MARK: - prefill

    private func makeImportedMetadata(_ json: String) throws -> ImportedMetadata {
        try ImportedMetadata(json: Data(json.utf8))
    }

    func testPrefillSetsImagesNameAndMetadataFields() throws {
        let imported = try makeImportedMetadata(#"""
        {
            "locale": "fr-FR", "location": { "name": "Turin", "latitude": 45.07, "longitude": 7.68, "countrycode": "ITA" },
            "flip": "book", "sentOn": "2024-05-01",
            "sender": { "name": "Alice", "uri": "https://example.com/alice" },
            "recipient": { "name": "Bob" },
            "front": {}, "back": {},
            "context": { "author": { "name": "Collector" }, "description": "Found at a market" }
        }
        """#)
        let bundle = PostcardImportBundle(
            name: "harbor-postcard",
            frontData: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), frontFilename: "harbor-postcard-front.png",
            backData: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), backFilename: "harbor-postcard-back.png",
            metadata: imported
        )

        let model = CreatePostcardModel()
        try model.prefill(bundle)

        XCTAssertEqual(model.name, "harbor-postcard")
        XCTAssertNotNil(model.front)
        XCTAssertNotNil(model.back)
        XCTAssertEqual(model.locale, "fr-FR")
        XCTAssertEqual(model.flip, .book)
        XCTAssertEqual(model.sentOn.map { Calendar(identifier: .iso8601).component(.year, from: $0) }, 2024)
        XCTAssertEqual(model.senderName, "Alice")
        XCTAssertEqual(model.senderURI, "https://example.com/alice")
        XCTAssertEqual(model.recipientName, "Bob")
        XCTAssertEqual(model.locationName, "Turin")
        XCTAssertEqual(model.locationLatitude ?? 0, 45.07, accuracy: 0.0001)
        XCTAssertEqual(model.locationCountryCode, "ITA")
        XCTAssertEqual(model.contextAuthorName, "Collector")
        XCTAssertEqual(model.contextDescription, "Found at a market")
    }

    /// One JSON fixture exercising all four skip flags' "present -> unskipped; absent ->
    /// that side's own default" rule (see `prefill`'s doc comment) — including two cases
    /// (`backTranscriptionSkipped`'s absent-default of `false`, `backDescriptionSkipped`'s
    /// present-override of a `true` default) that a naive "absent -> always skipped" rule
    /// would get wrong.
    func testPrefillDerivesSkipFlagsFromSideContent() throws {
        let imported = try makeImportedMetadata(#"""
        {
            "location": {}, "flip": "none", "sender": {}, "recipient": {},
            "front": { "description": "A sunny harbor", "transcription": { "text": "" } },
            "back": { "description": "A handwritten note", "transcription": { "text": "" } },
            "context": { "author": {} }
        }
        """#)
        let bundle = PostcardImportBundle(
            name: "card",
            frontData: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), frontFilename: "card-front.png",
            backData: nil, backFilename: nil,
            metadata: imported
        )

        let model = CreatePostcardModel()
        try model.prefill(bundle)

        XCTAssertFalse(model.frontDescriptionSkipped, "text present -> unskipped")
        XCTAssertTrue(model.frontTranscriptionSkipped, "text absent -> that side's own default (skipped)")
        XCTAssertFalse(model.backTranscriptionSkipped, "text absent -> that side's own default (unskipped)")
        XCTAssertFalse(model.backDescriptionSkipped, "text present -> unskipped, overriding a skipped-by-default side")
    }

    func testPrefillMapsPolygonAndBoxSecretsToNormalizedBoundingBoxes() throws {
        let imported = try makeImportedMetadata(#"""
        {
            "location": {}, "flip": "none", "sender": {}, "recipient": {},
            "front": { "secrets": [{ "type": "polygon", "prehidden": true, "points": [[0.1, 0.2], [0.4, 0.2], [0.4, 0.5], [0.1, 0.5]] }] },
            "back": { "secrets": [{ "type": "box", "prehidden": false, "left": 0.05, "top": 0.05, "width": 0.2, "height": 0.1 }] },
            "context": { "author": {} }
        }
        """#)
        let bundle = PostcardImportBundle(
            name: "card",
            frontData: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), frontFilename: "card-front.png",
            backData: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), backFilename: "card-back.png",
            metadata: imported
        )

        let model = CreatePostcardModel()
        try model.prefill(bundle)

        let frontSecret = try XCTUnwrap(model.frontSecrets.first)
        assertRect(frontSecret.rect, CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3))
        XCTAssertTrue(frontSecret.prehidden)

        let backSecret = try XCTUnwrap(model.backSecrets.first)
        assertRect(backSecret.rect, CGRect(x: 0.05, y: 0.05, width: 0.2, height: 0.1))
        XCTAssertFalse(backSecret.prehidden)
    }

    func testPrefillForcesDimensionsAndMarksThicknessAndColorTouchedWhenPhysicalPresent() throws {
        let imported = try makeImportedMetadata(#"""
        {
            "location": {}, "flip": "none", "sender": {}, "recipient": {},
            "front": {}, "back": {}, "context": { "author": {} },
            "physical": { "frontSize": { "cmW": "74/5", "cmH": "15", "pxW": 600, "pxH": 400 }, "thicknessMM": 0.6, "cardColor": "#112233" }
        }
        """#)
        let bundle = PostcardImportBundle(
            name: "card",
            frontData: makeImageData(width: 600, height: 400, dpi: nil, utType: "public.png"), frontFilename: "card-front.png",
            backData: nil, backFilename: nil,
            metadata: imported
        )

        let model = CreatePostcardModel()
        try model.prefill(bundle)

        XCTAssertEqual(model.cmWidthText, "14.8")
        XCTAssertEqual(model.cmHeightText, "15.0")
        XCTAssertTrue(model.dimensionsEdited)
        XCTAssertEqual(model.thicknessMM, 0.6)
        XCTAssertTrue(model.thicknessEdited)
        XCTAssertEqual(model.cardColorHex, "#112233")
        XCTAssertTrue(model.cardColorEdited)
    }

    func testPrefillWithoutMetadataOnlySetsImagesAndName() throws {
        let bundle = PostcardImportBundle(
            name: "trip",
            frontData: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), frontFilename: "trip-front.png",
            backData: nil, backFilename: nil,
            metadata: nil
        )

        let model = CreatePostcardModel()
        try model.prefill(bundle)

        XCTAssertEqual(model.name, "trip")
        XCTAssertNotNil(model.front)
        XCTAssertNil(model.back)
        let fresh = CreatePostcardModel()
        XCTAssertEqual(model.senderName, fresh.senderName)
        XCTAssertEqual(model.locationName, fresh.locationName)
        XCTAssertFalse(model.dimensionsEdited)
    }

    func testPrefillWithNoBackDataClearsAnyExistingBack() throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), filename: "old-front.png")
        try model.setBack(data: makeImageData(width: 90, height: 70, dpi: nil, utType: "public.png"), filename: "old-back.png")

        let bundle = PostcardImportBundle(
            name: "only-card",
            frontData: makeImageData(width: 100, height: 80, dpi: nil, utType: "public.png"), frontFilename: "only-card-only.png",
            backData: nil, backFilename: nil,
            metadata: nil
        )
        try model.prefill(bundle)

        XCTAssertNil(model.back, "\"-only\" (or a compiled front-only card) means front with no back")
    }
}
