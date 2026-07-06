import CoreLocation
import Foundation

/// The way a postcard's two sides are joined, mirroring `types.Flip` in the Go core.
/// Determines both the 3D tap-to-flip axis (see `FlipGeometry`) and whether the front
/// and back images have the same or different orientations.
enum Flip: String, Codable, Hashable, CaseIterable, Sendable {
    case book
    case leftHand = "left-hand"
    case calendar
    case rightHand = "right-hand"
    case none
}

/// A calendar date with no time-of-day or timezone component, matching `types.Date`'s
/// `"YYYY-MM-DD"` JSON representation. Implemented as its own Codable type (rather than
/// configuring `JSONDecoder.dateDecodingStrategy`) so every decoder works correctly
/// regardless of who constructs it.
struct PostcardDate: Codable, Hashable, Comparable, Sendable {
    var date: Date

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(date: Date) {
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let parsed = Self.formatter.date(from: string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a yyyy-MM-dd date, got \"\(string)\""
            )
        }
        date = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.formatter.string(from: date))
    }

    static func < (lhs: PostcardDate, rhs: PostcardDate) -> Bool { lhs.date < rhs.date }
}

/// Mirrors `types.Location`: a place name with optional coordinates and an ISO 3166-1
/// alpha-3 country code.
struct Location: Codable, Hashable, Sendable {
    var name: String?
    var latitude: Double?
    var longitude: Double?
    var countryCode: String?

    enum CodingKeys: String, CodingKey {
        case name, latitude, longitude
        case countryCode = "countrycode"
    }
}

/// Mirrors `types.Person`: a name plus an optional link (a website, social profile, etc).
struct Person: Codable, Hashable, Sendable {
    var name: String?
    var uri: String?
}

/// One annotation over a range of `AnnotatedText.text`, addressed in **UTF-8 byte
/// offsets** (not Unicode scalars or `Character`s) — see `AnnotatedTextRenderer` for how
/// these are converted into `String.Index`/`AttributedString.Index` ranges.
struct Annotation: Codable, Hashable, Sendable {
    var type: AnnotationType
    var value: String?
    var start: Int
    var end: Int
}

enum AnnotationType: String, Codable, Hashable, Sendable {
    case locale
    case emphasis = "em"
    case strong
    case underline
}

/// Mirrors `types.AnnotatedText`. The Go side always serializes this as an object (Go's
/// `encoding/json` `omitempty` has no effect on non-pointer struct fields), so both
/// `text` and `annotations` are decoded leniently with empty defaults.
struct AnnotatedText: Codable, Hashable, Sendable {
    var text: String
    var annotations: [Annotation]

    init(text: String = "", annotations: [Annotation] = []) {
        self.text = text
        self.annotations = annotations
    }

    private enum CodingKeys: String, CodingKey { case text, annotations }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        annotations = try container.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !text.isEmpty { try container.encode(text, forKey: .text) }
        if !annotations.isEmpty { try container.encode(annotations, forKey: .annotations) }
    }
}

/// Mirrors `types.Side`: one face of a postcard's description & transcription.
/// (`Secrets`/polygon regions aren't surfaced in the viewer, so they're omitted here —
/// `Decodable` simply ignores the unused JSON key.)
struct Side: Codable, Hashable, Sendable {
    var description: String?
    var transcription: AnnotatedText

    init(description: String? = nil, transcription: AnnotatedText = AnnotatedText()) {
        self.description = description
        self.transcription = transcription
    }

    private enum CodingKeys: String, CodingKey { case description, transcription }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        transcription = try container.decodeIfPresent(AnnotatedText.self, forKey: .transcription) ?? AnnotatedText()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(transcription, forKey: .transcription)
    }
}

/// Mirrors `types.Context`: who catalogued the postcard, and any extra notes.
struct Context: Codable, Hashable, Sendable {
    var author: Person
    var description: String?
}

/// Mirrors `types.Metadata`, the full per-card record returned by
/// `CardMetaJSON`/`MetaJSON`. Physical dimensions (`types.Physical`) aren't shown
/// anywhere in the viewer, so that field is intentionally left off this mirror —
/// `Decodable` ignores the unused `"physical"` key.
struct PostcardMetadata: Codable, Hashable, Sendable {
    var locale: String?
    var location: Location
    var flip: Flip
    var sentOn: PostcardDate?
    var sender: Person
    var recipient: Person
    var front: Side
    var back: Side
    var context: Context

    private enum CodingKeys: String, CodingKey {
        case locale, location, flip, sentOn, sender, recipient, front, back, context
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locale = try container.decodeIfPresent(String.self, forKey: .locale)
        location = try container.decodeIfPresent(Location.self, forKey: .location) ?? Location()
        flip = try container.decodeIfPresent(Flip.self, forKey: .flip) ?? .none
        sentOn = try container.decodeIfPresent(PostcardDate.self, forKey: .sentOn)
        sender = try container.decodeIfPresent(Person.self, forKey: .sender) ?? Person()
        recipient = try container.decodeIfPresent(Person.self, forKey: .recipient) ?? Person()
        front = try container.decodeIfPresent(Side.self, forKey: .front) ?? Side()
        back = try container.decodeIfPresent(Side.self, forKey: .back) ?? Side()
        context = try container.decodeIfPresent(Context.self, forKey: .context) ?? Context(author: Person(), description: nil)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(locale, forKey: .locale)
        try container.encode(location, forKey: .location)
        try container.encode(flip, forKey: .flip)
        try container.encodeIfPresent(sentOn, forKey: .sentOn)
        try container.encode(sender, forKey: .sender)
        try container.encode(recipient, forKey: .recipient)
        try container.encode(front, forKey: .front)
        try container.encode(back, forKey: .back)
        try container.encode(context, forKey: .context)
    }
}

/// Mirrors `collection.CardSummary`: everything needed to render a grid cell or list row
/// without decoding a card's image data.
struct CardSummary: Codable, Hashable, Identifiable, Sendable {
    var id: String { name }

    var name: String
    var filename: String
    var mimetype: String
    var flip: Flip
    var sentOn: PostcardDate?
    var senderName: String?
    var recipientName: String?
    var locationName: String?
    var countryCode: String?
    var latitude: Double?
    var longitude: Double?
    var frontPxW: Int
    var frontPxH: Int
    var hasBack: Bool

    enum CodingKeys: String, CodingKey {
        case name, filename, mimetype, flip
        case sentOn = "sent_on"
        case senderName = "sender_name"
        case recipientName = "recipient_name"
        case locationName = "location_name"
        case countryCode = "country_code"
        case latitude, longitude
        case frontPxW = "front_px_w"
        case frontPxH = "front_px_h"
        case hasBack = "has_back"
    }
}

extension CardSummary {
    /// `nil` unless the card carries both a latitude and longitude — the gate for whether
    /// it can appear as a pin in map mode (see `CollectionMapGating`).
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Mirrors `collection.SearchResult`, which embeds `CardSummary` — Go's JSON encoding
/// flattens the embedded struct's fields into the same object as `snippet`/`rank`, so
/// this re-decodes `CardSummary` from the very same keyed container instead of nesting it.
struct SearchResult: Codable, Hashable, Identifiable, Sendable {
    var id: String { card.id }

    var card: CardSummary
    var snippet: String
    var rank: Double

    private enum CodingKeys: String, CodingKey { case snippet, rank }

    init(from decoder: Decoder) throws {
        card = try CardSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snippet = try container.decode(String.self, forKey: .snippet)
        rank = try container.decode(Double.self, forKey: .rank)
    }

    func encode(to encoder: Encoder) throws {
        try card.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(snippet, forKey: .snippet)
        try container.encode(rank, forKey: .rank)
    }
}

/// Mirrors `appcore.libraryHit`: one hit from a cross-source `Library.SearchJSON` call.
/// Unlike `SearchResult`, `card` is nested here (Go's `libraryHit` has a named `Card` field).
struct LibraryHit: Codable, Hashable, Identifiable, Sendable {
    var id: String { source + "#" + card.name }

    var source: String
    var card: CardSummary
    var snippet: String
}
