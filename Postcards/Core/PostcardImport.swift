import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Classification, sibling discovery, and canonical-metadata decoding for dropping/picking
/// files onto "Create a Postcard" — the machinery behind `CreatePostcardModel.prefill(_:)`.
/// Three kinds of drop are recognised (see `DroppedKind`): a compiled postcard (metadata +
/// both images live wholesale in one file), a piece of dotpostcard's own component-file
/// convention (`{name}-front/back/only.<ext>` / `{name}-meta.<yaml|yml|json>`, mirroring Go's
/// `formats/component/bundle.go`), or a plain image (today's unchanged front/back behavior).

// MARK: - Classification

/// Which import path a single dropped/picked file takes.
enum DroppedKind: Equatable {
    /// `x.postcard` or `x.postcard.{jpg,jpeg,webp,png}` — a bare exported card, or a
    /// collection's own stored card file.
    case compiledPostcard
    /// One piece of the Go component-bundle naming convention.
    case componentPiece(ComponentStem)
    /// Anything else — today's plain-image behavior (first → front, second → back).
    case plainImage

    private static let compiledPostcardExtensions: Set<String> = ["jpg", "jpeg", "webp", "png"]

    /// Classifies by filename first (cheap, no bytes needed): `.postcard` alone, or
    /// `.postcard.<image-ext>`, or a component-bundle filename. A file matching neither falls
    /// back to sniffing `data` for embedded postcard XMP (`CardFileXMP.flip(in:)`) before
    /// settling on `plainImage` — a compiled postcard can arrive under any filename (e.g.
    /// shared out of Photos), so the filename check alone would silently treat it as a fresh
    /// scan. This is a pragmatic choice: the filename check covers the documented, common
    /// case cheaply; the XMP sniff is the fallback for a renamed file, not the primary test.
    static func classify(filename: String, data: Data) -> DroppedKind {
        if isCompiledPostcardFilename(filename) {
            return .compiledPostcard
        }
        if let stem = ComponentStem.parse(filename: filename) {
            return .componentPiece(stem)
        }
        if CardFileXMP.flip(in: data) != nil {
            return .compiledPostcard
        }
        return .plainImage
    }

    static func isCompiledPostcardFilename(_ filename: String) -> Bool {
        if filename.lowercased().hasSuffix(".postcard") { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard compiledPostcardExtensions.contains(ext) else { return false }
        let withoutExtension = (filename as NSString).deletingPathExtension
        return withoutExtension.lowercased().hasSuffix(".postcard")
    }

    /// `"x.postcard.jpg"` → `"x"`; `"x.postcard"` → `"x"` — strips from the last `.postcard`
    /// onward, whatever image extension (if any) follows it.
    static func compiledPostcardName(fromFilename filename: String) -> String {
        guard let range = filename.range(of: ".postcard", options: [.caseInsensitive, .backwards]) else {
            return filename
        }
        return String(filename[..<range.lowerBound])
    }
}

/// One file's parse against the Go component-bundle convention — mirrors
/// `formats/component/bundle.go`'s `bundleRE` (`^(.+)-(front|back|only)\.(webp|png|jpe?g|tiff?)$`
/// or `^(.+)-meta\.(yaml|json)$`), with `.yml` additionally accepted as a meta sidecar extension
/// per this app's own spec (Go's bundler itself only recognises `.yaml`/`.json`).
struct ComponentStem: Equatable {
    enum Role: Equatable {
        case front, back, only
        case meta(MetaFormat)
    }
    enum MetaFormat: Equatable { case yaml, json }

    let name: String
    let role: Role

    private static let regex = try! NSRegularExpression(
        pattern: #"^(.+)-(?:(front|back|only)\.(?:webp|png|jpe?g|tiff?)|meta\.(yaml|yml|json))$"#,
        options: [.caseInsensitive]
    )

    static func parse(filename: String) -> ComponentStem? {
        let fullRange = NSRange(filename.startIndex..., in: filename)
        guard
            let match = regex.firstMatch(in: filename, range: fullRange),
            let nameRange = Range(match.range(at: 1), in: filename)
        else {
            return nil
        }
        let name = String(filename[nameRange])

        if let roleRange = Range(match.range(at: 2), in: filename) {
            switch filename[roleRange].lowercased() {
            case "front": return ComponentStem(name: name, role: .front)
            case "back": return ComponentStem(name: name, role: .back)
            case "only": return ComponentStem(name: name, role: .only)
            default: return nil
            }
        }
        if let metaRange = Range(match.range(at: 3), in: filename) {
            switch filename[metaRange].lowercased() {
            case "yaml", "yml": return ComponentStem(name: name, role: .meta(.yaml))
            case "json": return ComponentStem(name: name, role: .meta(.json))
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Sibling discovery (macOS only)

enum ComponentBundleDiscovery {
    #if os(macOS)
    /// Every other file in `directory` belonging to `name`'s component bundle — front/back/
    /// only image and meta sidecar — found by re-parsing each filename in that directory
    /// against `ComponentStem.parse`, exactly as Go's own directory-group bundler does.
    /// iOS/watchOS have no equivalent: a sandboxed app can't enumerate a dropped file's
    /// siblings without the user granting each one individually, so callers there must only
    /// use what was actually dropped/picked together — this app is not sandboxed on macOS
    /// (see CLAUDE.md), so this is macOS-only by capability, not by choice.
    static func siblings(ofName name: String, in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents.filter { url in
            ComponentStem.parse(filename: url.lastPathComponent)?.name == name
        }
    }
    #endif
}

// MARK: - Rational strings

/// Parses Go's `math/big.Rat.MarshalText` wire format — a fraction like `"74/5"`, or a bare
/// integer like `"15"` (the form `big.Rat` emits when the denominator is 1) — into a `Double`.
/// Also accepts a plain decimal (`"15.5"`) leniently, since nothing here guarantees every
/// producer of this JSON shape is `big.Rat` (e.g. a hand-written `.json` sidecar).
enum GoRationalString {
    static func parse(_ string: String) -> Double? {
        let parts = string.split(separator: "/")
        guard let numerator = parts.first.flatMap({ Double($0) }) else { return nil }
        guard parts.count > 1 else { return numerator }
        guard let denominator = parts.last.flatMap({ Double($0) }), denominator != 0 else { return nil }
        return numerator / denominator
    }
}

// MARK: - Imported metadata

/// The canonical metadata JSON the new Go bindings return (`AppcoreMetaJSONFromCardBytes`,
/// `AppcoreMetaJSONFromComponentYAML`) — the same shape `PostcardMetadata` (Models.swift)
/// mirrors for reads, plus the `physical` and per-side `secrets` keys that type deliberately
/// omits (see its doc comment: neither is shown anywhere in the read-only viewer). Rather than
/// duplicating every field `PostcardMetadata` already decodes, this decodes the same JSON
/// twice — once as `PostcardMetadata`, once through the file-private probe structs below for
/// just the two keys it skips — and combines both here.
struct ImportedMetadata {
    var metadata: PostcardMetadata
    var physical: ImportedPhysical?
    var frontSecrets: [ImportedSecret]
    var backSecrets: [ImportedSecret]

    init(json: Data) throws {
        let decoder = JSONDecoder()
        metadata = try decoder.decode(PostcardMetadata.self, from: json)
        let probe = try decoder.decode(PhysicalAndSecretsProbe.self, from: json)
        physical = probe.physical
        frontSecrets = probe.front?.secrets ?? []
        backSecrets = probe.back?.secrets ?? []
    }
}

private struct PhysicalAndSecretsProbe: Decodable {
    var physical: ImportedPhysical?
    var front: SecretsProbe?
    var back: SecretsProbe?
}

private struct SecretsProbe: Decodable {
    var secrets: [ImportedSecret]?
}

/// `types.Physical`: `frontSize.cmW`/`cmH` (Go's `big.Rat` text form — see `GoRationalString`)
/// when the card has a known physical size, plus thickness/card colour when the source
/// explicitly set them (Go omits either from the JSON when unset, applying its own default at
/// read time instead — see `Physical.GetThicknessMM`/`GetCardColor`).
struct ImportedPhysical: Decodable {
    var cmWidth: Double?
    var cmHeight: Double?
    var thicknessMM: Double?
    var cardColor: String?

    private enum CodingKeys: String, CodingKey { case frontSize, thicknessMM, cardColor }
    private enum SizeCodingKeys: String, CodingKey { case cmW, cmH }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let size = try? container.nestedContainer(keyedBy: SizeCodingKeys.self, forKey: .frontSize) {
            cmWidth = try size.decodeIfPresent(String.self, forKey: .cmW).flatMap(GoRationalString.parse)
            cmHeight = try size.decodeIfPresent(String.self, forKey: .cmH).flatMap(GoRationalString.parse)
        }
        thicknessMM = try container.decodeIfPresent(Double.self, forKey: .thicknessMM)
        cardColor = try container.decodeIfPresent(String.self, forKey: .cardColor)
    }
}

/// One secret region as the canonical JSON encodes it: `types.SecretPolygon`'s `"type":
/// "polygon"` form (points array — what a round-tripped compiled card always carries, since
/// `hideSecrets` rewrites a box secret's corners into four points) or, leniently, a `"type":
/// "box"` form (left/top/width/height — accepted in case a hand-written `.json`/`.yaml`
/// sidecar uses it directly, since `types.Polygon`'s own unmarshaller accepts both). Either way
/// this app only edits rectangular regions, so a polygon's bounding box is what `rect` records.
struct ImportedSecret: Decodable {
    var rect: CGRect
    var prehidden: Bool

    private enum CodingKeys: String, CodingKey { case type, prehidden, points, left, top, width, height }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prehidden = try container.decodeIfPresent(Bool.self, forKey: .prehidden) ?? false
        let type = try container.decodeIfPresent(String.self, forKey: .type)

        if type == "box" {
            let left = try container.decodeIfPresent(Double.self, forKey: .left) ?? 0
            let top = try container.decodeIfPresent(Double.self, forKey: .top) ?? 0
            let width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0
            let height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 0
            rect = CGRect(x: left, y: top, width: width, height: height)
        } else {
            let points = try container.decodeIfPresent([[Double]].self, forKey: .points) ?? []
            rect = Self.boundingBox(ofPoints: points)
        }
    }

    private static func boundingBox(ofPoints points: [[Double]]) -> CGRect {
        let xs = points.compactMap { $0.first }
        let ys = points.compactMap { $0.count > 1 ? $0[1] : nil }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Resolution result

/// What `CreatePostcardModel.resolveImport(urls:)` determined about a drop/pick, before any of
/// it has touched the model — lets the caller (`CreatePostcardForm`) decide whether a replace
/// confirmation is needed purely by checking `PostcardImportBundle.metadata != nil` against
/// `CreatePostcardModel.isPristine`, without re-deriving any classification itself.
enum PostcardImportResolution {
    /// Category 3: hand the raw URLs straight to `CreatePostcardModel.importURLs(_:)`,
    /// unchanged from today's behavior.
    case plainImages([URL])
    /// Category 1 or 2: ready for `CreatePostcardModel.prefill(_:)`.
    case bundle(PostcardImportBundle)
}

/// Everything `CreatePostcardModel.prefill(_:)` needs to apply a compiled-postcard or
/// component-bundle import.
struct PostcardImportBundle {
    var name: String
    var frontData: Data
    var frontFilename: String
    var backData: Data?
    var backFilename: String?
    var metadata: ImportedMetadata?
    /// Set only for a genuine component-file drop (never a compiled `.postcard`) — see
    /// `ComponentProvenance`.
    var componentProvenance: ComponentProvenance? = nil
}

/// Where a component-bundle import's source files live on disk — captured for any
/// `{stem}-front/back/only` drop (with or without a meta sidecar already sitting beside it),
/// never for a compiled `.postcard` file or a plain image. `CreatePostcardModel
/// .componentProvenance` carries this forward so a successful create can write the
/// (possibly edited) metadata back beside those source files — see `writeSidecar(metadataJSON:)`
/// below and `CreatePostcardForm.create()`.
struct ComponentProvenance: Equatable {
    var directory: URL
    var stem: String
    /// The meta sidecar's own URL, when the import found one AND it was YAML (`.yaml` or
    /// `.yml`) — write-back overwrites that exact path, preserving a `.yml` extension rather
    /// than switching it to `.yaml`. `nil` when no sidecar existed yet, or the existing one was
    /// JSON (the Go binding backing `writeSidecar` only ever emits YAML bytes, so a `.json`
    /// sidecar can't be overwritten in place) — either way, write-back then defaults to
    /// `<stem>-meta.yaml`.
    var existingYAMLMetaURL: URL?

    var sidecarURL: URL {
        existingYAMLMetaURL ?? directory.appending(path: "\(stem)-meta.yaml")
    }

    /// Encodes `metadataJSON` (expected to be the SAME JSON just used to compile the card) into
    /// YAML via the Go core and writes it to `sidecarURL`, overwriting anything already there —
    /// that's the point: the fields the user just perfected in the form become the on-disk
    /// source of truth. macOS only in practice (sibling paths only exist, and the app is only
    /// unsandboxed, there — see CLAUDE.md); any failure (missing directory, permissions, or
    /// simply running on iOS) is swallowed and reported only via the return value, never
    /// thrown — a sidecar write must NEVER fail the create it's piggybacking on.
    @discardableResult
    func writeSidecar(metadataJSON: String) async -> Bool {
        #if os(macOS)
        do {
            let yaml = try await GoCore.shared.componentYAML(fromMetadataJSON: metadataJSON)
            try yaml.write(to: sidecarURL, options: .atomic)
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }
}

enum PostcardImportError: LocalizedError {
    case noFrontImage(name: String)
    case couldNotEncodeImage
    case couldNotSplitCompiledCard

    var errorDescription: String? {
        switch self {
        case .noFrontImage(let name):
            "No front image found for \"\(name)\" — expected \"\(name)-front.<ext>\" or \"\(name)-only.<ext>\"."
        case .couldNotEncodeImage:
            "Couldn't prepare that image for the postcard editor."
        case .couldNotSplitCompiledCard:
            "Couldn't read the front/back images out of that postcard file."
        }
    }
}

// MARK: - Resolution orchestration

extension CreatePostcardModel {
    /// Classifies and, for a compiled postcard or component bundle, fully resolves a
    /// drop/pick into a `PostcardImportBundle` ready for `prefill(_:)` — reading whatever
    /// bytes it needs (security-scoped), discovering sibling component files on macOS, and
    /// decoding metadata through the Go core. Classification looks only at `urls.first`
    /// (mirroring `importURLs(_:)`'s own "first two files, positionally" contract); a
    /// component bundle's OTHER pieces (front/back/meta) are gathered from the rest of `urls`
    /// plus, on macOS, sibling discovery — regardless of which piece happened to be first.
    static func resolveImport(urls: [URL]) async throws -> PostcardImportResolution {
        guard let first = urls.first else { return .plainImages(urls) }

        let firstData = try await Task.detached(priority: .userInitiated) {
            try readSecurityScopedData(at: first)
        }.value

        switch DroppedKind.classify(filename: first.lastPathComponent, data: firstData) {
        case .plainImage:
            return .plainImages(urls)

        case .compiledPostcard:
            return try await .bundle(resolveCompiledPostcard(url: first, data: firstData))

        case .componentPiece(let stem):
            let otherURLs = urls.dropFirst().filter { $0 != first }
            return try await .bundle(resolveComponentBundle(stem: stem, primaryURL: first, primaryData: firstData, otherURLs: Array(otherURLs)))
        }
    }

    // MARK: Compiled postcard

    private static func resolveCompiledPostcard(url: URL, data: Data) async throws -> PostcardImportBundle {
        let json = try await GoCore.shared.metadataJSON(fromCompiledCardBytes: data, filename: url.lastPathComponent)
        let imported = try ImportedMetadata(json: Data(json.utf8))

        let split: SplitPostcardImage
        do {
            split = try ImageSplitter.split(data: data, flip: imported.metadata.flip)
        } catch {
            throw PostcardImportError.couldNotSplitCompiledCard
        }

        let name = DroppedKind.compiledPostcardName(fromFilename: url.lastPathComponent)
        let frontData = try split.front.pngData()
        let backData = try split.back.map { try $0.pngData() }

        return PostcardImportBundle(
            name: name,
            frontData: frontData, frontFilename: "\(name)-front.png",
            backData: backData, backFilename: backData != nil ? "\(name)-back.png" : nil,
            metadata: imported
        )
    }

    // MARK: Component bundle

    private static func resolveComponentBundle(
        stem: ComponentStem, primaryURL: URL, primaryData: Data, otherURLs: [URL]
    ) async throws -> PostcardImportBundle {
        let name = stem.name
        var pool = otherURLs
        pool.append(primaryURL)
        #if os(macOS)
        let directory = primaryURL.deletingLastPathComponent()
        for sibling in ComponentBundleDiscovery.siblings(ofName: name, in: directory) where !pool.contains(sibling) {
            pool.append(sibling)
        }
        #endif

        var frontURL: URL?
        var onlyURL: URL?
        var backURL: URL?
        var metaMatch: (url: URL, format: ComponentStem.MetaFormat)?
        for url in pool {
            // Only a file belonging to the SAME stem name counts — the pool can contain
            // another card's pieces too (everything dropped together, plus every sibling in
            // the directory on macOS).
            guard let candidate = ComponentStem.parse(filename: url.lastPathComponent), candidate.name == name else { continue }
            switch candidate.role {
            case .front: frontURL = frontURL ?? url
            case .back: backURL = backURL ?? url
            case .only: onlyURL = onlyURL ?? url
            case .meta(let format): metaMatch = metaMatch ?? (url, format)
            }
        }

        let resolvedFrontURL: URL
        let skipBack: Bool
        if let frontURL {
            resolvedFrontURL = frontURL
            skipBack = false
        } else if let onlyURL {
            resolvedFrontURL = onlyURL
            skipBack = true
        } else {
            throw PostcardImportError.noFrontImage(name: name)
        }

        let frontData = try await readData(for: resolvedFrontURL, knownURL: primaryURL, knownData: primaryData)

        var backData: Data?
        if !skipBack, let backURL {
            backData = try await readData(for: backURL, knownURL: primaryURL, knownData: primaryData)
        }

        var metadata: ImportedMetadata?
        if let metaMatch {
            let metaBytes = try await readData(for: metaMatch.url, knownURL: primaryURL, knownData: primaryData)
            let json: Data
            switch metaMatch.format {
            case .json:
                json = metaBytes
            case .yaml:
                let jsonString = try await GoCore.shared.metadataJSON(fromComponentYAML: metaBytes)
                json = Data(jsonString.utf8)
            }
            metadata = try ImportedMetadata(json: json)
        }

        let provenance = ComponentProvenance(
            directory: resolvedFrontURL.deletingLastPathComponent(),
            stem: name,
            existingYAMLMetaURL: metaMatch?.format == .yaml ? metaMatch?.url : nil
        )

        return PostcardImportBundle(
            name: name,
            frontData: frontData, frontFilename: resolvedFrontURL.lastPathComponent,
            backData: backData, backFilename: backURL?.lastPathComponent,
            metadata: metadata,
            componentProvenance: provenance
        )
    }

    private static func readData(for url: URL, knownURL: URL, knownData: Data) async throws -> Data {
        if url == knownURL { return knownData }
        return try await Task.detached(priority: .userInitiated) {
            try readSecurityScopedData(at: url)
        }.value
    }
}

// MARK: - CGImage -> PNG

private extension CGImage {
    /// Lossless PNG re-encode — used only to turn a compiled postcard's split front/back
    /// `CGImage`s back into `Data` for `ProbedImage`/`setFront`/`setBack`, which need bytes,
    /// not a decoded image. No resize or filtering: the alpha edge (fibrous, soft-matted — see
    /// CLAUDE.md) must round-trip pixel for pixel, and the physical size comes from the
    /// imported metadata, not this file's own (absent) DPI.
    func pngData() throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw PostcardImportError.couldNotEncodeImage
        }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PostcardImportError.couldNotEncodeImage
        }
        return mutableData as Data
    }
}
