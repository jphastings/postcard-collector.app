import CoreGraphics
import Foundation
import ImageIO
import Postcards
import XCTest

/// True end-to-end coverage for "Create a Postcard": drives a real `CreatePostcardModel`
/// through the REAL Go core (`GoCore.compilePostcard`, `addCard`, and reopening a bare card
/// file) — no mocks, no `@testable import` (see README). Complements `CreatePostcardModelTests`
/// (the model's own logic, no Go involved) and `GoCoreTests` (GoCore's read/write paths against
/// a bundled fixture, never a freshly compiled card): this suite is the only place that proves
/// the model's `metadataJSON()` output is actually accepted by the vendored xcframework and
/// survives a real compile → add → reopen round trip.
@MainActor
final class CreatePostcardIntegrationTests: XCTestCase {
    // MARK: - Fixture generation

    /// A tiny in-memory PNG with a real pHYs (DPI) chunk, written via `CGImageDestination` —
    /// the same technique `CreatePostcardModelTests.makeImageData` uses for `ProbedImage`
    /// fixtures, but PNG specifically (not the default JPEG) so the Go core's resolution
    /// detection (`internal/resolution/png.go`, parsing the actual pHYs chunk) is what's under
    /// test, not just `ProbedImage`'s own header read.
    private func makeScanData(width: Int, height: Int, dpi: Double? = nil) -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
            XCTFail("couldn't create an image destination")
            return Data()
        }
        let image = makeTestImage(width: width, height: height) { x, y in
            (UInt8((x * 255) / max(width - 1, 1)), UInt8((y * 255) / max(height - 1, 1)), 120)
        }
        var properties: [CFString: Any] = [:]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return mutableData as Data
    }

    /// A fresh temp directory per test, cleaned up afterwards — same pattern as
    /// `GoCoreTests.makeTempCollectionPath`.
    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CreatePostcardIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A fully-populated model: 300dpi landscape front + back (same orientation, so `book`/
    /// `calendar` are the legal flips), every metadata field the plan's "Create a Postcard"
    /// form exposes, and one front secret region.
    private func makeFullModel(name: String) throws -> CreatePostcardModel {
        let model = CreatePostcardModel()
        try model.setFront(data: makeScanData(width: 600, height: 400, dpi: 300), filename: "\(name)-front.png")
        try model.setBack(data: makeScanData(width: 600, height: 400, dpi: 300), filename: "\(name)-back.png")
        model.name = name
        model.flip = model.allowedFlips.first ?? .book
        model.senderName = "Alice"
        model.senderURI = "https://example.com/alice"
        model.recipientName = "Bob"
        model.frontDescription = "A sunny harbor scene"
        model.backDescription = "A handwritten note"
        model.locationName = "Turin, Italy"
        model.locationLatitude = 45.07
        model.locationLongitude = 7.68
        model.locationCountryCode = "ITA"
        model.sentOn = Self.isoDate(year: 2024, month: 5, day: 1)
        model.frontSecrets = [SecretRegion(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2))]
        return model
    }

    private static func isoDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Raw metadata JSON (bypassing PostcardMetadata's read-only-viewer subset)

    /// Mirrors `GoCore.call`'s manual `NSErrorPointer` dance (see that type's doc comment) for
    /// the one raw Appcore call this suite needs directly.
    private func callGo<T>(_ body: (NSErrorPointer) -> T) throws -> T {
        var nsError: NSError?
        let result = body(&nsError)
        if let nsError { throw nsError }
        return result
    }

    /// `GoCore.metadata(ofCardFileAt:)` decodes into `PostcardMetadata` (Models.swift), which
    /// deliberately omits `physical` and `front`/`back.secrets` — fields the read-only viewer
    /// never shows (see that type's doc comment). Proving a forced physical size and a secret
    /// region round-trip needs the full raw JSON instead, so this opens the bare card file
    /// through the same `AppcoreOpenCardFile`/`metaJSON` calls `GoCore` itself uses internally,
    /// then hands back the parsed object for ad hoc inspection.
    private func rawMetadataJSONObject(ofCardFileAt path: String) throws -> [String: Any] {
        guard let cardFile = try callGo({ AppcoreOpenCardFile(path, $0) }) else {
            throw GoCoreError.openFailed(path)
        }
        let json = try callGo({ cardFile.metaJSON($0) })
        guard
            let data = json.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw GoCoreError.invalidJSON("reading raw metadata for \(path)")
        }
        return object
    }

    /// Go's `math/big.Rat` marshals as `MarshalText` — a fraction like `"74/5"`, not a plain
    /// decimal — so `physical.frontSize.cmW`/`cmH` need this instead of `Double(_:)`.
    private func parseGoRat(_ string: String) -> Double? {
        let parts = string.split(separator: "/")
        guard let numerator = parts.first.flatMap({ Double($0) }) else { return nil }
        guard parts.count > 1 else { return numerator }
        guard let denominator = parts.last.flatMap({ Double($0) }), denominator != 0 else { return nil }
        return numerator / denominator
    }

    // MARK: - Test 1: compile + add to a collection

    func testCompileAndAddToCollectionRoundTripsThroughRealGoCore() async throws {
        let model = try makeFullModel(name: "harbor-postcard")

        let compiled = try await GoCore.shared.compilePostcard(
            name: model.name,
            metadataJSON: try model.metadataJSON(),
            front: try XCTUnwrap(model.front?.data),
            back: model.back?.data,
            removeBorder: false,
            archival: false
        )

        XCTAssertTrue(
            compiled.filename.hasPrefix("harbor-postcard.postcard."),
            "filename \(compiled.filename) must be {name}.postcard.{ext}"
        )
        XCTAssertFalse(compiled.data.isEmpty)

        let collectionPath = try makeTempDirectory().appending(path: "created.postcards").path
        try await GoCore.shared.createCollection(at: collectionPath, title: "Created")
        try await GoCore.shared.addCard(filename: compiled.filename, data: compiled.data, toCollectionAt: collectionPath)

        let cards = try await GoCore.shared.cardSummaries(inCollectionAt: collectionPath)
        let card = try XCTUnwrap(cards.first)

        XCTAssertEqual(card.name, "harbor-postcard")
        XCTAssertEqual(card.senderName, "Alice")
        XCTAssertEqual(card.recipientName, "Bob")
        XCTAssertTrue(card.hasBack)
        XCTAssertEqual(card.frontPxW, 600)
        XCTAssertEqual(card.frontPxH, 400)
        XCTAssertEqual(card.locationName, "Turin, Italy")
        XCTAssertEqual(card.countryCode, "ITA")
        XCTAssertEqual(card.latitude ?? 0, 45.07, accuracy: 0.0001)
        XCTAssertEqual(card.longitude ?? 0, 7.68, accuracy: 0.0001)
        XCTAssertEqual(card.sentOn?.date, Self.isoDate(year: 2024, month: 5, day: 1))
    }

    // MARK: - Test 2: forced dimensions + secret region survive a bare-file round trip

    func testForcedDimensionsAndSecretRegionSurviveRoundTripThroughABareCardFile() async throws {
        let model = CreatePostcardModel()
        try model.setFront(data: makeScanData(width: 600, height: 400, dpi: 300), filename: "forced-size-front.png")
        model.name = "forced-size-card"

        // 15x10cm sits at exactly the front's 600x400 (1.5:1) pixel aspect ratio, so the
        // width field's aspect-linked auto-fill of the height (see
        // `CreatePostcardModel.cmWidthText`) lands on a known, exact value instead of a second
        // edit's recompute clobbering the first — a simple stand-in for "user typed 14.8x10.5".
        model.cmWidthText = "15.0"
        XCTAssertEqual(model.cmHeightText, "10.0", "aspect-linked auto-fill should land on an exact value")
        XCTAssertTrue(model.dimensionsEdited)

        model.frontSecrets = [SecretRegion(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2))]

        let compiled = try await GoCore.shared.compilePostcard(
            name: model.name,
            metadataJSON: try model.metadataJSON(),
            front: try XCTUnwrap(model.front?.data),
            back: nil,
            removeBorder: false,
            archival: false
        )

        let bareFileURL = try makeTempDirectory().appending(path: compiled.filename)
        try compiled.data.write(to: bareFileURL)

        // Reopen through GoCore's own bare-card-file API...
        let summary = try await GoCore.shared.summary(ofCardFileAt: bareFileURL.path)
        XCTAssertEqual(summary.name, "forced-size-card")
        XCTAssertFalse(summary.hasBack)
        XCTAssertEqual(summary.frontPxW, 600)
        XCTAssertEqual(summary.frontPxH, 400)

        // ...then drop to the raw metadata JSON for physical/secrets (see
        // `rawMetadataJSONObject`'s doc comment for why).
        let raw = try rawMetadataJSONObject(ofCardFileAt: bareFileURL.path)

        let physical = try XCTUnwrap(raw["physical"] as? [String: Any], "physical must survive the compile")
        let frontSize = try XCTUnwrap(physical["frontSize"] as? [String: Any])
        let cmWidth = try XCTUnwrap((frontSize["cmW"] as? String).flatMap(parseGoRat))
        let cmHeight = try XCTUnwrap((frontSize["cmH"] as? String).flatMap(parseGoRat))
        XCTAssertEqual(cmWidth, 15.0, accuracy: 0.01, "forced width must round-trip exactly, not be re-derived from DPI")
        XCTAssertEqual(cmHeight, 10.0, accuracy: 0.01)

        let front = try XCTUnwrap(raw["front"] as? [String: Any])
        let secrets = try XCTUnwrap(front["secrets"] as? [[String: Any]])
        XCTAssertEqual(secrets.count, 1, "the front secret region must survive the compile")
        XCTAssertEqual(
            secrets.first?["prehidden"] as? Bool, true,
            "secret pixels are painted over during compile, so prehidden must flip from false to true"
        )
    }

    // MARK: - Test 3: mismatched orientation + flip surfaces a readable Go error

    /// `CreatePostcardModel.reconcileFlip()` re-picks `flip` to a legal value the instant
    /// front/back orientations stop matching it, so the model's own API can never be driven
    /// into "landscape front + portrait back + flip book" — proven below before falling back
    /// to a hand-built bad `metadataJSON`, exactly as the plan's fallback describes. That
    /// hand-built JSON is what actually exercises the thing this test is about: that Go's
    /// `types.CheckFlip` validation error (`formats/component/decode.go` -> `pc.Validate()`)
    /// crosses the gobind bridge as a readable `Error.localizedDescription`, not just an opaque
    /// NSError code.
    ///
    /// No embedded DPI on either scan: `Size.SimilarPhysical` (also checked during decode, and
    /// checked BEFORE `CheckFlip`) short-circuits to "similar" when either side lacks physical
    /// info, so a DPI-less pair reaches the orientation check instead of tripping the (also
    /// genuine, but different) "different physical sizes" error first.
    func testMismatchedOrientationFlipSurfacesGoValidationError() async throws {
        let front = ProbedImage(data: Data(), pixelWidth: 900, pixelHeight: 600, dpiWidth: nil, dpiHeight: nil)
        let back = ProbedImage(data: Data(), pixelWidth: 600, pixelHeight: 900, dpiWidth: nil, dpiHeight: nil)
        XCTAssertFalse(
            CreatePostcardModel.allowedFlips(front: front, back: back).contains(.book),
            "the model must never offer 'book' for a heteroriented pair — this is why the bad JSON below is hand-built"
        )

        let frontData = makeScanData(width: 900, height: 600) // landscape, no DPI
        let backData = makeScanData(width: 600, height: 900) // portrait, no DPI
        let badMetadataJSON = #"{"flip":"book"}"#

        do {
            _ = try await GoCore.shared.compilePostcard(
                name: "mismatch",
                metadataJSON: badMetadataJSON,
                front: frontData,
                back: backData,
                removeBorder: false,
                archival: false
            )
            XCTFail("expected a landscape front + portrait back with flip \"book\" to be rejected")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("orientation") || message.localizedCaseInsensitiveContains("flip"),
                "expected a friendly orientation/flip error to cross the bridge, got: \(message)"
            )
        }
    }

    // MARK: - Test 4: dropping a compiled postcard prefills the whole form, through the real Go core

    /// The full "Create a Postcard" prefill loop: compile a rich card (metadata, a forced
    /// size, and a secret region) with the REAL Go core, write it to disk as a bare
    /// `.postcard.png` file exactly as a user would drop one, resolve + prefill a brand new
    /// model from it (`CreatePostcardModel.resolveImport(urls:)` -> `prefill(_:)`, both going
    /// through `AppcoreMetaJSONFromCardBytes`), and prove the result is itself a valid input to
    /// `compilePostcard` again — the round trip this whole feature exists to make possible.
    func testDroppingACompiledPostcardPrefillsAndReCompilesThroughRealGoCore() async throws {
        let sourceModel = try makeFullModel(name: "harbor-postcard")
        sourceModel.cmWidthText = "20.0" // a forced size, not just the scans' embedded DPI

        let compiled = try await GoCore.shared.compilePostcard(
            name: sourceModel.name,
            metadataJSON: try sourceModel.metadataJSON(),
            front: try XCTUnwrap(sourceModel.front?.data),
            back: sourceModel.back?.data,
            removeBorder: false,
            archival: false
        )

        let fileURL = try makeTempDirectory().appending(path: compiled.filename)
        try compiled.data.write(to: fileURL)

        guard case .bundle(let bundle) = try await CreatePostcardModel.resolveImport(urls: [fileURL]) else {
            return XCTFail("a compiled postcard file must resolve to a prefill bundle")
        }
        XCTAssertNotNil(bundle.metadata, "a compiled card's embedded XMP must decode as metadata")
        XCTAssertNil(bundle.componentProvenance, "a compiled .postcard file never carries component provenance")

        let importedModel = CreatePostcardModel()
        try importedModel.prefill(bundle)

        XCTAssertEqual(importedModel.name, "harbor-postcard")
        XCTAssertEqual(importedModel.senderName, "Alice")
        XCTAssertEqual(importedModel.recipientName, "Bob")
        XCTAssertEqual(importedModel.locationName, "Turin, Italy")
        XCTAssertEqual(importedModel.locationCountryCode, "ITA")
        XCTAssertEqual(importedModel.sentOn, Self.isoDate(year: 2024, month: 5, day: 1))
        XCTAssertEqual(importedModel.flip, sourceModel.flip)

        XCTAssertEqual(importedModel.front?.pixelWidth, 600, "the split front must match the original scan's pixels")
        XCTAssertEqual(importedModel.front?.pixelHeight, 400)
        XCTAssertEqual(importedModel.back?.pixelWidth, 600)
        XCTAssertEqual(importedModel.back?.pixelHeight, 400)

        XCTAssertTrue(importedModel.dimensionsEdited, "the re-encoded split images carry no DPI, so the imported cm size must be forced")
        XCTAssertEqual(Double(importedModel.cmWidthText) ?? 0, 20.0, accuracy: 0.1)

        let frontSecret = try XCTUnwrap(importedModel.frontSecrets.first)
        XCTAssertTrue(frontSecret.prehidden, "the secret's pixels were already painted over by the first compile")

        // The imported model's own `metadataJSON()` must itself be a valid `compilePostcard`
        // input — the round trip this feature exists to make possible.
        _ = try await GoCore.shared.compilePostcard(
            name: importedModel.name,
            metadataJSON: try importedModel.metadataJSON(),
            front: try XCTUnwrap(importedModel.front?.data),
            back: importedModel.back?.data,
            removeBorder: false,
            archival: false
        )
    }

    // MARK: - Test 5: dropping component pieces + a YAML meta sidecar prefills the form

    /// A `{name}-front.png` + `{name}-meta.yaml` pair, dropped as just the front image URL —
    /// proves macOS sibling discovery (`ComponentBundleDiscovery`) finds the sidecar on disk
    /// and `AppcoreMetaJSONFromComponentYAML` decodes it into the same prefill path a compiled
    /// card uses.
    func testDroppingAFrontImageWithAYAMLSidecarPrefillsViaSiblingDiscovery() async throws {
        let directory = try makeTempDirectory()
        let frontURL = directory.appending(path: "yaml-trip-front.png")
        try makeScanData(width: 300, height: 200).write(to: frontURL)

        let yaml = """
        locale: en-GB
        flip: none
        sender:
          name: Anon Ymous
          link: https://example.com
        front:
          description: A blue sky with fluffy white clouds
        physical:
          front_size: 12.33cm x 7.89cm
        """
        try yaml.write(to: directory.appending(path: "yaml-trip-meta.yaml"), atomically: true, encoding: .utf8)

        guard case .bundle(let bundle) = try await CreatePostcardModel.resolveImport(urls: [frontURL]) else {
            return XCTFail("a component front image must resolve to a prefill bundle")
        }
        XCTAssertNotNil(bundle.metadata, "the sibling meta.yaml must be discovered and decoded")
        XCTAssertNil(bundle.backData, "no -back sibling exists")
        let provenance = try XCTUnwrap(bundle.componentProvenance, "a component-file drop must carry provenance")
        // `.path` normalizes the trailing slash `deletingLastPathComponent()` adds; sibling
        // discovery's `FileManager.contentsOfDirectory` resolves through `/private/var/…` where
        // a freshly-built temp URL sits at the `/var/…` symlink, so the sidecar comparison also
        // needs `resolvingSymlinksInPath()` (same fix `LibraryModelImportTests.resolved(_:)` uses).
        XCTAssertEqual(provenance.directory.path, directory.path)
        XCTAssertEqual(provenance.stem, "yaml-trip")
        XCTAssertEqual(
            provenance.sidecarURL.resolvingSymlinksInPath().path,
            directory.appending(path: "yaml-trip-meta.yaml").resolvingSymlinksInPath().path,
            "an existing .yaml sidecar's exact path is reused"
        )

        let model = CreatePostcardModel()
        try model.prefill(bundle)

        XCTAssertEqual(model.componentProvenance, provenance)
        XCTAssertEqual(model.name, "yaml-trip")
        XCTAssertEqual(model.locale, "en-GB")
        XCTAssertEqual(model.senderName, "Anon Ymous")
        XCTAssertEqual(model.senderURI, "https://example.com")
        XCTAssertEqual(model.frontDescription, "A blue sky with fluffy white clouds")
        XCTAssertFalse(model.frontDescriptionSkipped)
        XCTAssertTrue(model.dimensionsEdited)
        XCTAssertEqual(Double(model.cmWidthText) ?? 0, 12.33, accuracy: 0.05)
        XCTAssertEqual(Double(model.cmHeightText) ?? 0, 7.89, accuracy: 0.05)
    }

    // MARK: - Test 6: component import -> edit -> sidecar write-back round trips

    /// The write-back half of "Create a Postcard" for component-file imports (feature 1 of the
    /// owner's two requests): drop `roundtrip-front.png` + an existing `roundtrip-meta.yml`
    /// sidecar (proving the `.yml` extension survives write-back, not just `.yaml`), edit a
    /// field, then call `ComponentProvenance.writeSidecar(metadataJSON:)` — the same helper
    /// `CreatePostcardForm.create()` calls right after a successful compile, from the SAME
    /// `metadataJSON` — directly against the REAL Go core (`AppcoreComponentYAMLFromMetaJSON`).
    /// Asserts the written bytes land at the exact imported path, use the CLI's own YAML key
    /// names, and decode back through `GoCore.metadataJSON(fromComponentYAML:)` with the edit
    /// intact — mirroring dotpostcard's own `TestComponentYAMLFromMetaJSONRoundTripsThrough
    /// MetaJSONFromComponentYAML` (pkg/appcore/import_test.go), which is why a box secret is
    /// expected to come back as `type: polygon` (`types.Polygon.MarshalYAML` always emits
    /// "polygon" — see that Go test's own comment).
    func testComponentImportEditThenWriteBackSidecarRoundTripsThroughRealGoCore() async throws {
        let directory = try makeTempDirectory()
        let frontURL = directory.appending(path: "roundtrip-front.png")
        try makeScanData(width: 400, height: 300, dpi: 300).write(to: frontURL)
        let metaURL = directory.appending(path: "roundtrip-meta.yml")
        let initialYAML = """
        locale: en-GB
        flip: none
        sender:
          name: Original Sender
        front:
          description: Original front description
        """
        try initialYAML.write(to: metaURL, atomically: true, encoding: .utf8)

        guard case .bundle(let bundle) = try await CreatePostcardModel.resolveImport(urls: [frontURL, metaURL]) else {
            return XCTFail("a component front image + meta.yml must resolve to a prefill bundle")
        }
        let provenance = try XCTUnwrap(bundle.componentProvenance)
        XCTAssertEqual(
            provenance.sidecarURL, metaURL,
            "an existing .yml sidecar's exact path must be reused, not switched to .yaml"
        )

        let model = CreatePostcardModel()
        try model.prefill(bundle)
        XCTAssertEqual(model.senderName, "Original Sender")

        // The fields the user "just perfected" in the form — exactly what write-back exists to
        // preserve.
        model.senderName = "Updated Sender"
        model.cmWidthText = "12.0" // forces physical.frontSize
        model.sentOn = Self.isoDate(year: 2023, month: 6, day: 15)
        model.frontSecrets = [SecretRegion(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2))]

        let metadataJSON = try model.metadataJSON()
        let outcome = await model.componentProvenance?.writeSidecar(metadataJSON: metadataJSON)
        XCTAssertEqual(outcome, true, "the write-back must succeed against a writable temp directory")

        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path), "the sidecar must land beside the source images")
        let writtenText = try String(contentsOf: metaURL, encoding: .utf8)
        for expectedKey in ["front_size:", "sent_on:", "type: polygon"] {
            XCTAssertTrue(writtenText.contains(expectedKey), "expected \"\(expectedKey)\" in the written YAML:\n\(writtenText)")
        }

        // Round-trips through the real Go core, same as re-importing this sidecar later would.
        let roundTrippedJSON = try await GoCore.shared.metadataJSON(fromComponentYAML: Data(writtenText.utf8))
        let imported = try ImportedMetadata(json: Data(roundTrippedJSON.utf8))
        XCTAssertEqual(imported.metadata.sender.name, "Updated Sender")
        XCTAssertEqual(imported.metadata.sentOn?.date, Self.isoDate(year: 2023, month: 6, day: 15))
        XCTAssertEqual(imported.physical?.cmWidth ?? 0, 12.0, accuracy: 0.01)
        XCTAssertEqual(imported.frontSecrets.count, 1, "the front secret must survive the write-back round trip")
    }

    // MARK: - Test 7: sidecar write-back is a no-op without componentProvenance

    /// A card with no component-import origin (e.g. built from plain scans) has no
    /// `componentProvenance`, so there's nothing to write back — proven directly against the
    /// optional-chained call `CreatePostcardForm.create()` makes.
    func testWriteSidecarIsSkippedWithoutComponentProvenance() async throws {
        let model = try makeFullModel(name: "no-provenance")
        XCTAssertNil(model.componentProvenance)

        let outcome = await model.componentProvenance?.writeSidecar(metadataJSON: try model.metadataJSON())
        XCTAssertNil(outcome, "nothing to write back, so the optional chain never calls into Go at all")
    }
}
