import CoreGraphics
import Foundation
import ImageIO
import Observation

/// The pixel size and (if embedded) DPI of a candidate scan, read from the image header only
/// — `CGImageSourceCopyPropertiesAtIndex` never decodes pixels, so this is cheap enough to
/// call on every drop/import before the user has committed to anything.
struct ProbedImage: Equatable, Sendable {
    /// A per-image identity independent of content — `data`'s own hash is expensive to
    /// recompute for a tens-of-megapixel scan on every SwiftUI diff, and unlike `data` this
    /// survives `swap(&front, &back)` still pointing at the same picture, which is exactly
    /// what the stage's swap `matchedGeometryEffect` (and its preview-decode `.task(id:)`)
    /// need to key on.
    var id: UUID = UUID()
    var data: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var dpiWidth: Double?
    var dpiHeight: Double?

    /// `cm = px / dpi × 2.54`, when this side's DPI is known — the size the cm fields prefill
    /// with before any edit. `nil` (rather than a guessed size) when DPI is missing, so the
    /// UI can show its own placeholder instead of a number nobody actually measured.
    var suggestedCmWidth: Double? { dpiWidth.map { Double(pixelWidth) / $0 * 2.54 } }
    var suggestedCmHeight: Double? { dpiHeight.map { Double(pixelHeight) / $0 * 2.54 } }

    static func probe(data: Data) -> ProbedImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            return nil
        }
        return ProbedImage(
            data: data,
            pixelWidth: width,
            pixelHeight: height,
            dpiWidth: (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue,
            dpiHeight: (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
        )
    }
}

/// State for the "Create a Postcard" flow: two candidate scans, the physical size they imply,
/// metadata, and per-side secret regions — everything needed to build the JSON the Go compile
/// pipeline expects (`metadataJSON()`) and the blocking issues that gate `canCreate`.
///
/// SwiftUI-free by design (Foundation/Observation/ImageIO/CoreGraphics only — CoreGraphics is
/// the shared, cross-platform home of `CGRect`, which `SecretRegion` is built on) so it
/// compiles into the watch/QuickLook targets' dependency graph and PostcardsTests without
/// pulling in any view code; nothing here touches the Go core (see `GoCore.compilePostcard`).
@MainActor
@Observable
final class CreatePostcardModel {
    enum CreateIssue: Equatable, Sendable {
        case missingFrontImage
        case invalidName
        case illegalFlip

        var message: String {
            switch self {
            case .missingFrontImage: "Add a front image."
            case .invalidName: "Give the card a name — it can't contain \"/\"."
            case .illegalFlip: "Choose a flip that matches these images' orientations."
            }
        }
    }

    enum ProbeError: LocalizedError {
        case unreadableImage(String)

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let filename): "Couldn't read \"\(filename)\" as an image."
            }
        }
    }

    enum MetadataError: LocalizedError {
        case invalidDimensions

        var errorDescription: String? {
            switch self {
            case .invalidDimensions: "Enter a valid width and height — open the size chip to fix it."
            }
        }
    }

    private enum Orientation: Equatable {
        case landscape, portrait, square
    }

    /// One step of the describe/transcribe wizard `CreatePostcardForm` walks through —
    /// structure only (which side, which kind, and key paths to this model's own text/skip
    /// storage the view can build a `Binding` from); prompt copy stays in the view. Ordered
    /// front description → front transcription → back transcription → back description;
    /// `describeSteps` drops the back pair when there's no back image.
    enum DescribeStep: Hashable, Sendable {
        case frontDescription
        case frontTranscription
        case backTranscription
        case backDescription

        enum Side: Hashable, Sendable { case front, back }
        enum Kind: Sendable { case description, transcription }

        var side: Side {
            switch self {
            case .frontDescription, .frontTranscription: .front
            case .backTranscription, .backDescription: .back
            }
        }

        var kind: Kind {
            switch self {
            case .frontDescription, .backDescription: .description
            case .frontTranscription, .backTranscription: .transcription
            }
        }

        // `@MainActor`-isolated (like every stored property they point at): forming a key path
        // to an actor-isolated member is itself isolated, and is an error rather than a
        // warning once this module adopts the Swift 6 language mode.
        @MainActor
        var textKeyPath: ReferenceWritableKeyPath<CreatePostcardModel, String> {
            switch self {
            case .frontDescription: \.frontDescription
            case .frontTranscription: \.frontTranscription
            case .backTranscription: \.backTranscription
            case .backDescription: \.backDescription
            }
        }

        @MainActor
        var skipKeyPath: ReferenceWritableKeyPath<CreatePostcardModel, Bool> {
            switch self {
            case .frontDescription: \.frontDescriptionSkipped
            case .frontTranscription: \.frontTranscriptionSkipped
            case .backTranscription: \.backTranscriptionSkipped
            case .backDescription: \.backDescriptionSkipped
            }
        }
    }

    // MARK: - Images

    private(set) var front: ProbedImage?
    private(set) var back: ProbedImage?

    // MARK: - Name

    /// Defaults from the front filename (see `derivedName(fromFilename:)`) until the user
    /// types their own — a later front swap must not clobber a name they've already chosen.
    var name: String = "" {
        didSet {
            guard !isApplyingDerivedName else { return }
            nameEdited = true
        }
    }
    private var nameEdited = false
    private var isApplyingDerivedName = false

    // MARK: - Physical size

    var cmWidthText: String = "" {
        didSet {
            guard !isSyncingDimensions else { return }
            dimensionsEdited = true
            guard let front, front.pixelWidth > 0, let width = Double(cmWidthText), width > 0 else { return }
            isSyncingDimensions = true
            cmHeightText = Self.formattedCm(width * Double(front.pixelHeight) / Double(front.pixelWidth))
            isSyncingDimensions = false
        }
    }
    var cmHeightText: String = "" {
        didSet {
            guard !isSyncingDimensions else { return }
            dimensionsEdited = true
            guard let front, front.pixelHeight > 0, let height = Double(cmHeightText), height > 0 else { return }
            isSyncingDimensions = true
            cmWidthText = Self.formattedCm(height * Double(front.pixelWidth) / Double(front.pixelHeight))
            isSyncingDimensions = false
        }
    }
    /// True once the user has typed into either cm field — the gate for whether
    /// `metadataJSON()` sends a forced `physical.frontSize` at all (unedited, Go keeps the
    /// exact embedded rational resolution instead of this preview's rounded decimal).
    private(set) var dimensionsEdited = false
    private var isSyncingDimensions = false

    // MARK: - Flip

    var flip: Flip = .none

    // MARK: - Metadata fields

    var locale: String = Locale.current.identifier(.bcp47)
    var sentOn: Date?
    var senderName: String = ""
    var senderURI: String = ""
    var recipientName: String = ""
    var recipientURI: String = ""
    var locationName: String = ""
    var locationLatitude: Double?
    var locationLongitude: Double?
    var locationCountryCode: String = ""
    var frontDescription: String = ""
    var frontTranscription: String = ""
    var backDescription: String = ""
    var backTranscription: String = ""
    var contextAuthorName: String = ""
    var contextAuthorURI: String = ""
    var contextDescription: String = ""

    // MARK: - Describe/transcribe skip flags

    /// Whether each side's description/transcription is deliberately skipped — omitted from
    /// `metadataJSON()` regardless of any text already typed (see that method), so un-skipping
    /// restores it rather than losing it. Defaults favor the common case (fronts are usually
    /// worth describing, backs rarely have handwriting on them) until the user actively
    /// touches a flag, at which point `swapSides()` carries *that* choice with its content
    /// instead of re-deriving the default.
    var frontDescriptionSkipped = false {
        didSet {
            guard !isApplyingSkipDefault else { return }
            frontDescriptionSkippedTouched = true
        }
    }
    var frontTranscriptionSkipped = true {
        didSet {
            guard !isApplyingSkipDefault else { return }
            frontTranscriptionSkippedTouched = true
        }
    }
    var backTranscriptionSkipped = false {
        didSet {
            guard !isApplyingSkipDefault else { return }
            backTranscriptionSkippedTouched = true
        }
    }
    var backDescriptionSkipped = true {
        didSet {
            guard !isApplyingSkipDefault else { return }
            backDescriptionSkippedTouched = true
        }
    }
    private var frontDescriptionSkippedTouched = false
    private var frontTranscriptionSkippedTouched = false
    private var backTranscriptionSkippedTouched = false
    private var backDescriptionSkippedTouched = false
    private var isApplyingSkipDefault = false

    /// The describe/transcribe wizard's steps in order — the back pair only appears once a
    /// back image exists (see `DescribeStep`).
    var describeSteps: [DescribeStep] {
        var steps: [DescribeStep] = [.frontDescription, .frontTranscription]
        if back != nil {
            steps += [.backTranscription, .backDescription]
        }
        return steps
    }

    var thicknessMM: Double = 0.4 { didSet { thicknessEdited = true } }
    private(set) var thicknessEdited = false
    var cardColorHex: String = "#E6E6D9" { didSet { cardColorEdited = true } }
    private(set) var cardColorEdited = false

    var removeBorder = false
    var archival = false

    var frontSecrets: [SecretRegion] = []
    var backSecrets: [SecretRegion] = []

    /// Preselected from `LibraryModel.lastSelectedCollectionPath` by the (out-of-scope) form
    /// view. `nil` is itself a valid destination — "Individual postcards," a bare file (see
    /// `LibraryModel.addBareCard`) — not an unset one, so it never blocks `canCreate`.
    var destinationCollectionPath: String?

    // MARK: - Ephemeral UI state

    /// Which side (if any) the describe/transcribe wizard's focused text editor is currently
    /// about, so `PostcardStage` can zoom the left pane to just that side while the user is
    /// typing. Purely a view-coordination signal — never read by `metadataJSON()` and never
    /// persisted — it lives on this model only because it's the shared home `DescribeWizard`
    /// (the writer) and `PostcardStage` (the reader) already both observe.
    var spotlightSide: DescribeStep.Side?

    init() {}

    // MARK: - Reset

    /// Restores every piece of state to a freshly-initialized model's values. Built by
    /// constructing a fresh instance and copying its properties across — routed through the
    /// same suppression flags `setFront()`/`swapSides()` use so their `didSet` observers don't
    /// mistake the reset for a user edit — rather than resetting each field by hand, so state
    /// added to `init()` later is picked up here automatically instead of silently drifting
    /// out of sync with it.
    func reset() {
        let fresh = CreatePostcardModel()

        front = fresh.front
        back = fresh.back

        isApplyingDerivedName = true
        name = fresh.name
        isApplyingDerivedName = false
        nameEdited = fresh.nameEdited

        isSyncingDimensions = true
        cmWidthText = fresh.cmWidthText
        cmHeightText = fresh.cmHeightText
        isSyncingDimensions = false
        dimensionsEdited = fresh.dimensionsEdited

        flip = fresh.flip

        locale = fresh.locale
        sentOn = fresh.sentOn
        senderName = fresh.senderName
        senderURI = fresh.senderURI
        recipientName = fresh.recipientName
        recipientURI = fresh.recipientURI
        locationName = fresh.locationName
        locationLatitude = fresh.locationLatitude
        locationLongitude = fresh.locationLongitude
        locationCountryCode = fresh.locationCountryCode
        frontDescription = fresh.frontDescription
        frontTranscription = fresh.frontTranscription
        backDescription = fresh.backDescription
        backTranscription = fresh.backTranscription
        contextAuthorName = fresh.contextAuthorName
        contextAuthorURI = fresh.contextAuthorURI
        contextDescription = fresh.contextDescription

        isApplyingSkipDefault = true
        frontDescriptionSkipped = fresh.frontDescriptionSkipped
        frontTranscriptionSkipped = fresh.frontTranscriptionSkipped
        backTranscriptionSkipped = fresh.backTranscriptionSkipped
        backDescriptionSkipped = fresh.backDescriptionSkipped
        isApplyingSkipDefault = false
        frontDescriptionSkippedTouched = fresh.frontDescriptionSkippedTouched
        frontTranscriptionSkippedTouched = fresh.frontTranscriptionSkippedTouched
        backTranscriptionSkippedTouched = fresh.backTranscriptionSkippedTouched
        backDescriptionSkippedTouched = fresh.backDescriptionSkippedTouched

        thicknessMM = fresh.thicknessMM
        thicknessEdited = fresh.thicknessEdited
        cardColorHex = fresh.cardColorHex
        cardColorEdited = fresh.cardColorEdited

        removeBorder = fresh.removeBorder
        archival = fresh.archival

        frontSecrets = fresh.frontSecrets
        backSecrets = fresh.backSecrets

        destinationCollectionPath = fresh.destinationCollectionPath

        spotlightSide = fresh.spotlightSide
    }

    // MARK: - Pristine check

    /// Whether every user-enterable field still holds a fresh model's value — the gate for
    /// whether importing a compiled postcard/component bundle (see `PostcardImport.swift`)
    /// can prefill silently or needs a "replace the current postcard?" confirmation first
    /// (mirroring the Reset confirmation — see `CreatePostcardForm`). Deliberately excludes
    /// `destinationCollectionPath` (preselected by the form before the user has touched
    /// anything — see that property's doc comment) and `spotlightSide` (ephemeral wizard-focus
    /// UI state): neither represents postcard content, so neither should force a confirmation
    /// on its own. Compares the same fields `CreatePostcardModelTests`' reset tests exercise.
    var isPristine: Bool {
        let fresh = CreatePostcardModel()
        return front == nil
            && back == nil
            && name == fresh.name
            && cmWidthText == fresh.cmWidthText
            && cmHeightText == fresh.cmHeightText
            && flip == fresh.flip
            && locale == fresh.locale
            && sentOn == fresh.sentOn
            && senderName == fresh.senderName
            && senderURI == fresh.senderURI
            && recipientName == fresh.recipientName
            && recipientURI == fresh.recipientURI
            && locationName == fresh.locationName
            && locationLatitude == fresh.locationLatitude
            && locationLongitude == fresh.locationLongitude
            && locationCountryCode == fresh.locationCountryCode
            && frontDescription == fresh.frontDescription
            && frontTranscription == fresh.frontTranscription
            && backDescription == fresh.backDescription
            && backTranscription == fresh.backTranscription
            && contextAuthorName == fresh.contextAuthorName
            && contextAuthorURI == fresh.contextAuthorURI
            && contextDescription == fresh.contextDescription
            && frontDescriptionSkipped == fresh.frontDescriptionSkipped
            && frontTranscriptionSkipped == fresh.frontTranscriptionSkipped
            && backTranscriptionSkipped == fresh.backTranscriptionSkipped
            && backDescriptionSkipped == fresh.backDescriptionSkipped
            && thicknessMM == fresh.thicknessMM
            && cardColorHex == fresh.cardColorHex
            && removeBorder == fresh.removeBorder
            && archival == fresh.archival
            && frontSecrets == fresh.frontSecrets
            && backSecrets == fresh.backSecrets
    }

    // MARK: - Prefill (compiled postcard / component bundle import)

    /// Applies a resolved import (see `PostcardImport.resolveImport(urls:)`) onto this model:
    /// front/back images, name, and — when a compiled card's XMP or a component meta sidecar
    /// was found — every metadata field this form exposes. Always overwrites unconditionally
    /// rather than merging; callers gate whether that's appropriate via `isPristine` and a
    /// replace confirmation (`CreatePostcardForm`), so by the time this runs the model is
    /// assumed to already be either freshly `reset()` or itself pristine — there's nothing
    /// stale left over that this doesn't already set.
    func prefill(_ bundle: PostcardImportBundle) throws {
        try setFront(data: bundle.frontData, filename: bundle.frontFilename)
        if let backData = bundle.backData {
            try setBack(data: backData, filename: bundle.backFilename ?? "\(bundle.name)-back")
        } else {
            clearBack()
        }

        isApplyingDerivedName = true
        name = bundle.name
        isApplyingDerivedName = false
        nameEdited = true

        guard let imported = bundle.metadata else { return }
        let meta = imported.metadata

        if let locale = meta.locale { self.locale = locale }
        flip = meta.flip
        sentOn = meta.sentOn?.date
        senderName = meta.sender.name ?? ""
        senderURI = meta.sender.uri ?? ""
        recipientName = meta.recipient.name ?? ""
        recipientURI = meta.recipient.uri ?? ""
        locationName = meta.location.name ?? ""
        locationLatitude = meta.location.latitude
        locationLongitude = meta.location.longitude
        locationCountryCode = meta.location.countryCode ?? ""
        contextAuthorName = meta.context.author.name ?? ""
        contextAuthorURI = meta.context.author.uri ?? ""
        contextDescription = meta.context.description ?? ""

        frontDescription = meta.front.description ?? ""
        frontTranscription = meta.front.transcription.text
        backDescription = meta.back.description ?? ""
        backTranscription = meta.back.transcription.text

        // A skip flag derives from content, not from touching it: text present -> unskipped;
        // absent -> falls back to that side's own fresh default (see the skip flags' doc
        // comment above), exactly like `reset()`/`swapSides()`'s own `isApplyingSkipDefault`
        // suppression — so un-skipping later still behaves like a first, genuine user choice.
        let fresh = CreatePostcardModel()
        isApplyingSkipDefault = true
        frontDescriptionSkipped = frontDescription.isEmpty ? fresh.frontDescriptionSkipped : false
        frontTranscriptionSkipped = frontTranscription.isEmpty ? fresh.frontTranscriptionSkipped : false
        backTranscriptionSkipped = backTranscription.isEmpty ? fresh.backTranscriptionSkipped : false
        backDescriptionSkipped = backDescription.isEmpty ? fresh.backDescriptionSkipped : false
        isApplyingSkipDefault = false

        frontSecrets = imported.frontSecrets.map { SecretRegion(rect: $0.rect, prehidden: $0.prehidden) }
        backSecrets = imported.backSecrets.map { SecretRegion(rect: $0.rect, prehidden: $0.prehidden) }

        if let physical = imported.physical {
            if let cmWidth = physical.cmWidth, let cmHeight = physical.cmHeight, cmWidth > 0, cmHeight > 0 {
                isSyncingDimensions = true
                cmWidthText = Self.formattedCm(cmWidth)
                cmHeightText = Self.formattedCm(cmHeight)
                isSyncingDimensions = false
                dimensionsEdited = true
            }
            if let thicknessMM = physical.thicknessMM {
                self.thicknessMM = thicknessMM
            }
            if let cardColor = physical.cardColor {
                cardColorHex = cardColor
            }
        }
    }

    // MARK: - Setting images

    /// The single-drop-zone entry point: fills whichever slot is next (front, then back),
    /// or replaces the back if both are already filled — a fresh drop always means "this is
    /// the new back," so its stale secret regions (drawn against the old back's pixels) are
    /// cleared along with it. `setFront`/`setBack` stay around underneath for the same
    /// probing/name/dimension logic.
    func addImage(data: Data, filename: String) throws {
        if front == nil {
            try setFront(data: data, filename: filename)
        } else if back == nil {
            try setBack(data: data, filename: filename)
        } else {
            backSecrets = []
            try setBack(data: data, filename: filename)
        }
    }

    /// Reads up to the first two dropped/picked file URLs and adds each via `addImage` —
    /// the shared landing point for both the window-root drop zone (`CreatePostcardForm`) and
    /// the stage's own file-picker button (`PostcardStage`), so neither duplicates the
    /// security-scoped-read dance. Stops at the first unreadable file, leaving any images
    /// already added in place.
    func importURLs(_ urls: [URL]) async throws {
        for url in urls.prefix(2) {
            let data = try await Task.detached(priority: .userInitiated) {
                try Self.readSecurityScopedData(at: url)
            }.value
            try addImage(data: data, filename: url.lastPathComponent)
        }
    }

    /// Reads a picked/dropped file's bytes immediately, retaining nothing scoped — mirrors
    /// `LibraryModel.copyIntoContainer`'s security-scope + coordinated-read bracketing, minus
    /// the copy (only the bytes are needed in memory). Not `private`: `PostcardImport.swift`'s
    /// `resolveImport(urls:)` reuses this same dance to read a compiled card/component piece's
    /// bytes before classification decides what to do with them.
    nonisolated static func readSecurityScopedData(at url: URL) throws -> Data {
        let hasScope = url.startAccessingSecurityScopedResource()
        defer { if hasScope { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var data: Data?
        var readError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            do {
                data = try Data(contentsOf: readableURL)
            } catch {
                readError = error
            }
        }
        if let error = coordinationError ?? readError { throw error }
        guard let data else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    /// Clears the front slot only — leaves `back` untouched. To promote a remaining back
    /// image into the now-empty front slot, follow with `swapSides()` (which already handles
    /// exactly that case).
    func clearFront() {
        front = nil
        frontSecrets = []
        reconcileFlip()
    }

    /// Exchanges every piece of state belonging to "the front" and "the back": images,
    /// secrets, description/transcription text, and the skip flags (a *touched* flag's value
    /// travels with its content to the other side; an untouched one re-derives that side's own
    /// default instead of carrying the old side's value across — see the skip flags' doc
    /// comment). A no-op when there's no back image, since a lone front already belongs in the
    /// front slot; when only a back image exists this promotes it to front, since the front
    /// slot must end non-nil whenever any image exists.
    func swapSides() {
        guard back != nil else { return }

        swap(&front, &back)
        swap(&frontSecrets, &backSecrets)
        swap(&frontDescription, &backDescription)
        swap(&frontTranscription, &backTranscription)

        let description = Self.swappedSkipPair(
            frontValue: frontDescriptionSkipped, frontTouched: frontDescriptionSkippedTouched, frontDefault: false,
            backValue: backDescriptionSkipped, backTouched: backDescriptionSkippedTouched, backDefault: true
        )
        let transcription = Self.swappedSkipPair(
            frontValue: frontTranscriptionSkipped, frontTouched: frontTranscriptionSkippedTouched, frontDefault: true,
            backValue: backTranscriptionSkipped, backTouched: backTranscriptionSkippedTouched, backDefault: false
        )

        isApplyingSkipDefault = true
        frontDescriptionSkipped = description.newFrontValue
        backDescriptionSkipped = description.newBackValue
        frontTranscriptionSkipped = transcription.newFrontValue
        backTranscriptionSkipped = transcription.newBackValue
        isApplyingSkipDefault = false
        frontDescriptionSkippedTouched = description.newFrontTouched
        backDescriptionSkippedTouched = description.newBackTouched
        frontTranscriptionSkippedTouched = transcription.newFrontTouched
        backTranscriptionSkippedTouched = transcription.newBackTouched

        reconcileFlip()
        reseedDimensions()
    }

    /// One skip flag's new (value, touched) on each side after a swap: a touched flag's value
    /// travels to the other side (which is now touched, carrying that conscious choice with
    /// its content); an untouched side re-derives its own default and stays untouched.
    private static func swappedSkipPair(
        frontValue: Bool, frontTouched: Bool, frontDefault: Bool,
        backValue: Bool, backTouched: Bool, backDefault: Bool
    ) -> (newFrontValue: Bool, newFrontTouched: Bool, newBackValue: Bool, newBackTouched: Bool) {
        (
            newFrontValue: backTouched ? backValue : frontDefault,
            newFrontTouched: backTouched,
            newBackValue: frontTouched ? frontValue : backDefault,
            newBackTouched: frontTouched
        )
    }

    /// Probes and stores the front image, deriving the default name (unless already edited)
    /// and reseeding the cm fields from its embedded DPI.
    func setFront(data: Data, filename: String) throws {
        guard let probed = ProbedImage.probe(data: data) else {
            throw ProbeError.unreadableImage(filename)
        }
        front = probed
        applyDerivedName(from: filename)
        reseedDimensions()
        reconcileFlip()
    }

    /// Probes and stores the back image. Doesn't touch the name or cm fields — only the
    /// front's DPI drives the size preview — but re-picks `flip` if the current choice is no
    /// longer legal for the new pair of orientations.
    func setBack(data: Data, filename: String) throws {
        guard let probed = ProbedImage.probe(data: data) else {
            throw ProbeError.unreadableImage(filename)
        }
        back = probed
        reconcileFlip()
    }

    func clearBack() {
        back = nil
        backSecrets = []
        reconcileFlip()
    }

    // MARK: - Name derivation

    /// Strips the extension and a trailing `-front`/`-only` marker: `"scan-front.tiff"` →
    /// `"scan"`, `"holiday-only.png"` → `"holiday"`.
    static func derivedName(fromFilename filename: String) -> String {
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        for suffix in ["-front", "-only"] where stem.lowercased().hasSuffix(suffix) {
            return String(stem.dropLast(suffix.count))
        }
        return stem
    }

    private func applyDerivedName(from filename: String) {
        guard !nameEdited else { return }
        isApplyingDerivedName = true
        name = Self.derivedName(fromFilename: filename)
        isApplyingDerivedName = false
    }

    // MARK: - Dimensions

    private func reseedDimensions() {
        isSyncingDimensions = true
        if let width = front?.suggestedCmWidth, let height = front?.suggestedCmHeight {
            cmWidthText = Self.formattedCm(width)
            cmHeightText = Self.formattedCm(height)
        } else {
            cmWidthText = ""
            cmHeightText = ""
        }
        isSyncingDimensions = false
        dimensionsEdited = false
    }

    private static func formattedCm(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// "10.5 × 14.8 cm" for the stage's dimensions chip — reads the same cm fields the chip's
    /// popover edits (not `front.suggestedCmWidth/Height` directly), so a user override
    /// displays identically to a DPI-derived default. `nil` (rendered as "Set size…" by the
    /// chip) only when neither field currently parses to a positive number.
    var dimensionsChipText: String? {
        guard let width = Double(cmWidthText), width > 0, let height = Double(cmHeightText), height > 0 else {
            return nil
        }
        return "\(Self.formattedCm(width)) × \(Self.formattedCm(height)) cm"
    }

    /// The dimensions chip popover's footnote: where the current cm values came from.
    var dimensionsSourceFootnote: String {
        if dimensionsEdited {
            return "Custom size — overrides the scan's embedded resolution."
        }
        if let dpi = front?.dpiWidth {
            return "From the scan's \(Int(dpi.rounded())) dpi resolution."
        }
        return "No size info in the scan."
    }

    // MARK: - Flip legality

    /// Mirrors `types.CheckFlip` in the Go core: a square front (within 5px of square)
    /// permits any flip; a same-orientation pair only the two axis flips; a
    /// different-orientation pair only the two diagonal flips. No back image means no flip.
    static func allowedFlips(front: ProbedImage, back: ProbedImage?) -> [Flip] {
        guard let back else { return [.none] }
        let frontOrientation = orientation(pixelWidth: front.pixelWidth, pixelHeight: front.pixelHeight)
        if frontOrientation == .square {
            return [.book, .calendar, .leftHand, .rightHand]
        }
        let backOrientation = orientation(pixelWidth: back.pixelWidth, pixelHeight: back.pixelHeight)
        return frontOrientation == backOrientation ? [.book, .calendar] : [.leftHand, .rightHand]
    }

    private static func orientation(pixelWidth: Int, pixelHeight: Int) -> Orientation {
        if abs(pixelWidth - pixelHeight) <= 5 { return .square }
        return pixelWidth > pixelHeight ? .landscape : .portrait
    }

    var allowedFlips: [Flip] {
        guard let front else { return [.none] }
        return Self.allowedFlips(front: front, back: back)
    }

    /// Re-picks `flip` to the first allowed value (mirroring the "default flip = first
    /// allowed" rule) whenever the current choice stops being legal — called after any change
    /// to `front`/`back`. Leaves a still-legal choice untouched.
    private func reconcileFlip() {
        let allowed = allowedFlips
        if !allowed.contains(flip) {
            flip = allowed.first ?? .none
        }
    }

    // MARK: - Physical size mismatch

    /// Mirrors `types.Size.SimilarPhysical`: compares the two sides' embedded-DPI-derived cm
    /// sizes within 1%, swapping width/height for the two heteroriented flips. This is the
    /// check Go enforces regardless of any user override of the cm fields, so it's surfaced
    /// early here — `nil` when either side lacks embedded DPI (nothing to compare).
    static func physicalMismatchWarning(front: ProbedImage, back: ProbedImage, flip: Flip) -> String? {
        guard
            let frontWidth = front.suggestedCmWidth, let frontHeight = front.suggestedCmHeight,
            let backWidth = back.suggestedCmWidth, let backHeight = back.suggestedCmHeight
        else {
            return nil
        }

        let matches = flip.isHeteroriented
            ? similar(frontWidth, backHeight) && similar(frontHeight, backWidth)
            : similar(frontWidth, backWidth) && similar(frontHeight, backHeight)
        guard !matches else { return nil }
        return "The front and back scans' embedded sizes disagree — their DPI implies different physical dimensions."
    }

    private static func similar(_ a: Double, _ b: Double) -> Bool {
        guard a != 0, b != 0 else { return true }
        return abs(1 - a / b) <= 0.01
    }

    var physicalMismatchWarning: String? {
        guard let front, let back else { return nil }
        return Self.physicalMismatchWarning(front: front, back: back, flip: flip)
    }

    // MARK: - Alt text nudge

    /// True when the front lacks a description, or a back image is present but lacks one —
    /// never a blocker (see `canCreate`), just an encouragement. A side whose description is
    /// explicitly skipped never nudges: that's a conscious choice, not an oversight.
    var altTextNudge: Bool {
        if !frontDescriptionSkipped, frontDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if back != nil, !backDescriptionSkipped, backDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    // MARK: - Create gating

    /// `destinationCollectionPath == nil` is a valid destination ("Individual postcards", a
    /// bare file — see `LibraryModel.addBareCard`), not a missing one, so it never blocks.
    var blockingIssues: [CreateIssue] {
        var issues: [CreateIssue] = []
        if front == nil { issues.append(.missingFrontImage) }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName.contains("/") { issues.append(.invalidName) }
        if !allowedFlips.contains(flip) { issues.append(.illegalFlip) }
        return issues
    }

    var canCreate: Bool { blockingIssues.isEmpty }

    // MARK: - Metadata JSON

    /// Builds the JSON the Go compile pipeline expects (see the plan's "Swift↔Go metadata
    /// contract"): the same shape `PostcardMetadata` mirrors for reads, plus `physical` and
    /// per-side `secrets`. `PostcardMetadata`/`Side` (Models.swift) have no memberwise
    /// initializer — only `init(from: Decoder)` — so they can't be constructed here; this
    /// builds the equivalent JSON shape directly instead (`MetadataPayload`, file-private
    /// below), matching `Side`'s own `CodingKeys`/`encode(to:)` with `secrets` added.
    func metadataJSON() throws -> String {
        let location = Location(
            name: locationName.isEmpty ? nil : locationName,
            latitude: locationLatitude,
            longitude: locationLongitude,
            countryCode: locationCountryCode.isEmpty ? nil : locationCountryCode
        )
        let sender = Person(name: senderName.isEmpty ? nil : senderName, uri: senderURI.isEmpty ? nil : senderURI)
        let recipient = Person(name: recipientName.isEmpty ? nil : recipientName, uri: recipientURI.isEmpty ? nil : recipientURI)
        let contextAuthor = Person(name: contextAuthorName.isEmpty ? nil : contextAuthorName, uri: contextAuthorURI.isEmpty ? nil : contextAuthorURI)
        let context = Context(author: contextAuthor, description: contextDescription.isEmpty ? nil : contextDescription)
        // A skipped field is left out of the payload even if there's text sitting in the
        // model — the model itself is untouched, so un-skipping later restores it.
        let frontSide = Side(
            description: (frontDescriptionSkipped || frontDescription.isEmpty) ? nil : frontDescription,
            transcription: frontTranscriptionSkipped ? AnnotatedText() : AnnotatedText(text: frontTranscription)
        )
        let backSide = Side(
            description: (backDescriptionSkipped || backDescription.isEmpty) ? nil : backDescription,
            transcription: backTranscriptionSkipped ? AnnotatedText() : AnnotatedText(text: backTranscription)
        )

        var physical: PhysicalPayload?
        if dimensionsEdited {
            let width = cmWidthText.trimmingCharacters(in: .whitespaces)
            let height = cmHeightText.trimmingCharacters(in: .whitespaces)
            guard let widthValue = Double(width), widthValue > 0, let heightValue = Double(height), heightValue > 0 else {
                throw MetadataError.invalidDimensions
            }
            physical = PhysicalPayload(cmWidth: width, cmHeight: height, thicknessMM: nil, cardColor: nil)
        }
        if thicknessEdited || cardColorEdited {
            var updated = physical ?? PhysicalPayload(cmWidth: nil, cmHeight: nil, thicknessMM: nil, cardColor: nil)
            if thicknessEdited { updated.thicknessMM = thicknessMM }
            if cardColorEdited { updated.cardColor = cardColorHex }
            physical = updated
        }

        let payload = MetadataPayload(
            locale: locale.isEmpty ? nil : locale,
            location: location,
            flip: back == nil ? .none : flip,
            sentOn: sentOn.map(PostcardDate.init),
            sender: sender,
            recipient: recipient,
            front: frontSide,
            frontSecrets: frontSecrets,
            back: backSide,
            backSecrets: backSecrets,
            context: context,
            physical: physical
        )

        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The `metadataJSON()` wire payload — see that method's doc comment for why this doesn't
/// wrap a constructed `PostcardMetadata`.
private struct MetadataPayload: Encodable {
    var locale: String?
    var location: Location
    var flip: Flip
    var sentOn: PostcardDate?
    var sender: Person
    var recipient: Person
    var front: Side
    var frontSecrets: [SecretRegion]
    var back: Side
    var backSecrets: [SecretRegion]
    var context: Context
    var physical: PhysicalPayload?

    private enum CodingKeys: String, CodingKey {
        case locale, location, flip, sentOn, sender, recipient, front, back, context, physical
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encode(location, forKey: .location)
        try container.encode(flip, forKey: .flip)
        try container.encodeIfPresent(sentOn, forKey: .sentOn)
        try container.encode(sender, forKey: .sender)
        try container.encode(recipient, forKey: .recipient)
        try container.encode(SideWithSecrets(side: front, secrets: frontSecrets), forKey: .front)
        try container.encode(SideWithSecrets(side: back, secrets: backSecrets), forKey: .back)
        try container.encode(context, forKey: .context)
        try container.encodeIfPresent(physical, forKey: .physical)
    }
}

/// `Side` (Models.swift) plus `secrets` — mirrors `Side.encode(to:)`'s own `CodingKeys`
/// exactly (same keys, same `encodeIfPresent`/`encode` split) with one key added, since
/// `Side` itself can't be extended to carry secrets without touching Models.swift.
private struct SideWithSecrets: Encodable {
    var side: Side
    var secrets: [SecretRegion]

    private enum CodingKeys: String, CodingKey { case description, transcription, secrets }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(side.description, forKey: .description)
        try container.encode(side.transcription, forKey: .transcription)
        if !secrets.isEmpty {
            try container.encode(secrets.map(SecretPayload.init), forKey: .secrets)
        }
    }
}

/// One `SecretRegion` as the box-secret JSON `types.Polygon` unmarshals (`types/secrets.go`):
/// always `type: "box"` with normalized 0–1 coordinates.
private struct SecretPayload: Encodable {
    var region: SecretRegion

    private enum CodingKeys: String, CodingKey { case type, prehidden, left, top, width, height }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("box", forKey: .type)
        try container.encode(region.prehidden, forKey: .prehidden)
        try container.encode(Double(region.rect.minX), forKey: .left)
        try container.encode(Double(region.rect.minY), forKey: .top)
        try container.encode(Double(region.rect.width), forKey: .width)
        try container.encode(Double(region.rect.height), forKey: .height)
    }
}

/// `types.Physical`: `frontSize` only when the caller has a forced size to send; `thicknessMM`
/// / `cardColor` only when the user actually touched those fields (Go otherwise applies its
/// own defaults — see `Physical.GetThicknessMM`/`GetCardColor`).
private struct PhysicalPayload: Encodable {
    var cmWidth: String?
    var cmHeight: String?
    var thicknessMM: Double?
    var cardColor: String?

    private enum CodingKeys: String, CodingKey { case frontSize, thicknessMM, cardColor }
    private enum SizeCodingKeys: String, CodingKey { case cmW, cmH }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let cmWidth, let cmHeight {
            var size = container.nestedContainer(keyedBy: SizeCodingKeys.self, forKey: .frontSize)
            try size.encode(cmWidth, forKey: .cmW)
            try size.encode(cmHeight, forKey: .cmH)
        }
        try container.encodeIfPresent(thicknessMM, forKey: .thicknessMM)
        try container.encodeIfPresent(cardColor, forKey: .cardColor)
    }
}
