# Postcards

A read-only SwiftUI viewer for `*.postcards` collections and bare `*.postcard.*` files,
over a Go core (see [dotpostcard](https://github.com/jphastings/dotpostcard)) vendored as
an XCFramework. iOS 17+ and macOS 14+.

This app is the MVP milestone described in Part 2 / Part 3 milestones 4-5 of the project
plan: a bundled fixture collection, `.fileImporter`-based opening of collections/cards from
disk, a searchable grid, and a 3D tap-to-flip detail view with a metadata panel. iCloud
sync (milestone 6) and motion-driven parallax (milestone 7) are not implemented yet.

## Layout

- `Postcards/App/` — the `App` entry point (`PostcardsApp.swift`), a single
  `NavigationSplitView` (sidebar of sources → grid → detail).
- `Postcards/Core/` — everything with no SwiftUI dependency, plus the platform-image glue:
  - `GoCore.swift` — an `actor` wrapping the generated `Appcore` Objective-C API, so every
    call into the Go core happens off the main thread. Also documents the gobind/Swift
    error-bridging quirks (see comments) that determine which calls throw and which take
    a manual error pointer.
  - `Models.swift` — Codable mirrors of the Go core's JSON shapes (`CardSummary`,
    `SearchResult`, `PostcardMetadata`, …), matching its `json`/`yaml` tags field-for-field.
  - `ImageSplitter.swift` — splits a card's combined (stacked front+back) image into its
    two sides using CoreGraphics/ImageIO, mirroring `formats/web/decode.go`. Includes the
    hand-flip un-rotation, with the CW/CCW direction derived from tracing
    `formats/web/encode.go`'s `rotateForWeb` and empirically verified by
    `ImageSplitterTests` (corner-marker images, not just reasoning about it).
  - `FlipGeometry.swift` — the `Flip` → 3D rotation axis mapping, kept independent of
    SwiftUI so it's trivially unit-testable.
  - `AnnotatedTextRenderer.swift` — `AnnotatedText` → `AttributedString`, converting
    **UTF-8 byte offsets** (not `Character` offsets) into `String`/`AttributedString`
    indices.
  - `CountryFlags.swift`, `PlatformImage.swift`, `LibrarySource.swift`, `LibraryModel.swift`
    — smaller supporting pieces (flag emoji from ISO 3166-1 alpha-3 codes, a
    `UIImage`/`NSImage` typealias, and the sidebar's source list).
- `Postcards/Views/` — `LibraryView` (sidebar + file importer), `CollectionGridView`
  (searchable grid, thumbnails via `NSCache`), `CardDetailView` + `FlipEffect.swift`
  (the tap-to-flip card), `CardInfoPanel` (sheet on iOS / inspector on macOS).
- `Postcards/Fixtures/` — a bundled sample collection (`fixture.postcards`, four cards
  covering all four flip types) and one bare card file, for the app to show with nothing
  configured.
- `PostcardsTests/` — logic-only unit tests, compiled directly against `Postcards/Core`
  (no `@testable import`, no host application). Covers: JSON decoding against real
  payloads captured from the Go core, `ImageSplitter`'s crop/rotation directions and
  dimensions, `AnnotatedTextRenderer`'s UTF-8 offset math (including German/Japanese
  multi-byte fixtures), and the `FlipGeometry` axis table.
- `Frameworks/Postcards.xcframework` — vendored, not committed (see below).
- `project.yml` — the [XcodeGen](https://github.com/yonaskolb/XcodeGen) source of truth;
  `Postcards.xcodeproj` is generated from it and also not committed.

## Regenerating the Xcode project

```sh
brew install xcodegen   # if needed
xcodegen generate
```

Run this after editing `project.yml` or adding/removing files (XcodeGen lists files
explicitly rather than watching folders, so new files need a regenerate to show up).

## Rebuilding the XCFramework

The framework is built from the Go core repo, not this one:

```sh
cd /path/to/dotpostcard
make xcframework
cp -R build/Postcards.xcframework /path/to/postcard-collector-app/Frameworks/
```

## Verifying a build

```sh
xcodegen generate
xcodebuild -project Postcards.xcodeproj -scheme Postcards-macOS \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
xcodebuild -project Postcards.xcodeproj -scheme Postcards-iOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Postcards.xcodeproj -scheme PostcardsTests \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO test
```

## Known simplifications (vs. the full project plan)

- No iCloud entitlements/`NSMetadataQuery` sync, and no security-scoped bookmark
  persistence — sources opened via the file importer aren't remembered across launches.
  No signing team is required to build as a result.
- No motion-driven parallax tilt on the detail view.
- `GoCore` wraps `Library`'s cross-source search (`setLibrarySources`/`searchLibrary`),
  but `CollectionGridView` only wires up per-collection search for now — an "Everywhere"
  search scope over every open source is the natural next step, once there's a
  motivating multi-source scenario (iCloud).
