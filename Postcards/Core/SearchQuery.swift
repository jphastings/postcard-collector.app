import Foundation

/// A structured search query for the Go core's filtered search endpoints
/// (`searchFilteredJSON`), mirroring Go's `SearchFilter` 1:1. Every field but `text` is
/// omitted from the encoded JSON when empty, matching Go's `omitempty` tags on the other
/// side — since `JSONEncoder` has no built-in support for that, `encode(to:)` is written by
/// hand (the same pattern `AnnotatedText`/`Side` use in Models.swift) rather than making the
/// arrays optional, so callers can keep working with plain, always-present `[String]`s.
struct SearchQuery: Equatable, Codable {
    var text: String
    var from: [String]
    var to: [String]
    var with: [String]
    var collector: [String]
    var country: [String]
    var sentFrom: String?
    var sentUntil: String?

    init(
        text: String = "",
        from: [String] = [],
        to: [String] = [],
        with: [String] = [],
        collector: [String] = [],
        country: [String] = [],
        sentFrom: String? = nil,
        sentUntil: String? = nil
    ) {
        self.text = text
        self.from = from
        self.to = to
        self.with = with
        self.collector = collector
        self.country = country
        self.sentFrom = sentFrom
        self.sentUntil = sentUntil
    }

    private enum CodingKeys: String, CodingKey {
        case text, from, to, with, collector, country
        case sentFrom = "sent_from"
        case sentUntil = "sent_until"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        from = try container.decodeIfPresent([String].self, forKey: .from) ?? []
        to = try container.decodeIfPresent([String].self, forKey: .to) ?? []
        with = try container.decodeIfPresent([String].self, forKey: .with) ?? []
        collector = try container.decodeIfPresent([String].self, forKey: .collector) ?? []
        country = try container.decodeIfPresent([String].self, forKey: .country) ?? []
        sentFrom = try container.decodeIfPresent(String.self, forKey: .sentFrom)
        sentUntil = try container.decodeIfPresent(String.self, forKey: .sentUntil)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if !text.isEmpty { try container.encode(text, forKey: .text) }
        if !from.isEmpty { try container.encode(from, forKey: .from) }
        if !to.isEmpty { try container.encode(to, forKey: .to) }
        if !with.isEmpty { try container.encode(with, forKey: .with) }
        if !collector.isEmpty { try container.encode(collector, forKey: .collector) }
        if !country.isEmpty { try container.encode(country, forKey: .country) }
        try container.encodeIfPresent(sentFrom, forKey: .sentFrom)
        try container.encodeIfPresent(sentUntil, forKey: .sentUntil)
    }

    /// True iff nothing but free text is set — i.e. this query has no effect beyond what the
    /// existing plain-text search already does, so callers can keep using the unfiltered
    /// search method instead of paying for a filtered round-trip.
    var isPlainText: Bool {
        from.isEmpty && to.isEmpty && with.isEmpty && collector.isEmpty && country.isEmpty
            && sentFrom == nil && sentUntil == nil
    }

    /// This query, JSON-encoded for `searchFilteredJSON` — `nil` only if encoding somehow
    /// fails (it can't, in practice: every field here is a plain `String`/`[String]`).
    var filterJSON: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Parsing

    private static let recognizedTags: Set<String> = ["from", "to", "with", "collector", "country", "on", "before", "after"]

    /// Parses a search bar's free-typed text into a structured query. Recognized tags
    /// (case-insensitive): `from`, `to`, `with`, `collector`, `country`, `on`, `before`,
    /// `after`, each written `tag:value` or `tag:"quoted value"`. Anything else — including
    /// an unrecognized `tag:value` token — is treated as free text and appended verbatim to
    /// `text` (tokens joined by single spaces, trimmed).
    static func parse(_ raw: String) -> SearchQuery {
        var query = SearchQuery()
        var textTokens: [String] = []

        for token in tokenize(raw) {
            guard let (tag, value) = splitTag(token) else {
                textTokens.append(token)
                continue
            }
            switch tag {
            case "from": query.from.append(value)
            case "to": query.to.append(value)
            case "with": query.with.append(value)
            case "collector": query.collector.append(value)
            case "country": query.country.append(normalisedCountryCode(value))
            case "on", "before", "after":
                if !applyDateTag(tag, value: value, to: &query) {
                    textTokens.append(token)
                }
            default:
                textTokens.append(token)
            }
        }

        query.text = textTokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return query
    }

    /// A hand-rolled scanner rather than `raw.split(separator: " ")`, so a `"` can hold
    /// whitespace inside one token — required for `tag:"quoted value with spaces"` (and, more
    /// generally, any `"..."` span anywhere in the input). Quote characters themselves are
    /// dropped from the returned tokens.
    ///
    /// Internal rather than `private` so `SearchToken.promote(from:)` can reuse the exact
    /// same tokenization `parse` uses, instead of duplicating it.
    static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false

        var iterator = raw.makeIterator()
        var pending: Character? = iterator.next()

        func advance() { pending = iterator.next() }

        while let character = pending {
            if character.isWhitespace {
                if inToken {
                    tokens.append(current)
                    current = ""
                    inToken = false
                }
                advance()
                continue
            }
            inToken = true
            if character == "\"" {
                advance()
                while let quoted = pending, quoted != "\"" {
                    current.append(quoted)
                    advance()
                }
                if pending == "\"" { advance() }
            } else {
                current.append(character)
                advance()
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }

    /// Splits a token into `(tag, value)` if it starts with a recognized tag followed by a
    /// colon and a non-empty value — using the FIRST colon only, so a URI value containing
    /// its own colons (`from:mailto:claire@example.com`) still splits into tag `from` and
    /// value `mailto:claire@example.com`.
    ///
    /// Internal rather than `private` so `SearchToken.promote(from:)` can reuse it too.
    static func splitTag(_ token: String) -> (tag: String, value: String)? {
        guard let colonIndex = token.firstIndex(of: ":") else { return nil }
        let tag = token[token.startIndex..<colonIndex].lowercased()
        let value = token[token.index(after: colonIndex)...]
        guard recognizedTags.contains(tag), !value.isEmpty else { return nil }
        return (tag, String(value))
    }

    // MARK: - Dates

    /// `X` may be `yyyy`, `yyyy-MM`, or `yyyy-MM-dd`. Returns `(start, end)` as `yyyy-MM-dd`
    /// strings, where `end` is the first day AFTER the period (exclusive upper bound) —
    /// computed via `Calendar`/`DateComponents` so month/year rollover (e.g. `2024-12` →
    /// `2025-01-01`) is always correct. `nil` if `X` isn't one of those three forms.
    private static func dateRange(for value: String) -> (start: String, end: String)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)

        let year: Int
        let month: Int?
        let day: Int?

        switch parts.count {
        case 1:
            guard parts[0].count == 4, let parsedYear = Int(parts[0]) else { return nil }
            year = parsedYear
            month = nil
            day = nil
        case 2:
            guard parts[0].count == 4, let parsedYear = Int(parts[0]),
                  parts[1].count == 2, let parsedMonth = Int(parts[1]), (1...12).contains(parsedMonth) else { return nil }
            year = parsedYear
            month = parsedMonth
            day = nil
        case 3:
            guard parts[0].count == 4, let parsedYear = Int(parts[0]),
                  parts[1].count == 2, let parsedMonth = Int(parts[1]), (1...12).contains(parsedMonth),
                  parts[2].count == 2, let parsedDay = Int(parts[2]), (1...31).contains(parsedDay) else { return nil }
            year = parsedYear
            month = parsedMonth
            day = parsedDay
        default:
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let startComponents = DateComponents(year: year, month: month ?? 1, day: day ?? 1)
        guard let startDate = calendar.date(from: startComponents) else { return nil }

        let addedComponent: Calendar.Component = day != nil ? .day : (month != nil ? .month : .year)
        guard let endDate = calendar.date(byAdding: addedComponent, value: 1, to: startDate) else { return nil }

        return (isoString(startDate, calendar: calendar), isoString(endDate, calendar: calendar))
    }

    private static func isoString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Applies one `on`/`before`/`after` date tag to `query`, tightening (never loosening) any
    /// existing bound: `on:X` sets `sentFrom = max(existing, start(X))` and
    /// `sentUntil = min(existing, end(X))`; `before:X` sets `sentUntil = min(existing,
    /// start(X))`; `after:X` sets `sentFrom = max(existing, end(X))`. Multiple tags of any of
    /// these three kinds combine left-to-right via this same max/min logic, with `nil`
    /// treated as unbounded (so the first date tag simply sets the value outright).
    private static func apply(_ range: (start: String, end: String), kind: String, to query: inout SearchQuery) {
        switch kind {
        case "on":
            query.sentFrom = tighten(query.sentFrom, range.start, by: max)
            query.sentUntil = tighten(query.sentUntil, range.end, by: min)
        case "before":
            query.sentUntil = tighten(query.sentUntil, range.start, by: min)
        case "after":
            query.sentFrom = tighten(query.sentFrom, range.end, by: max)
        default:
            break
        }
    }

    /// ISO `yyyy-MM-dd` strings compare lexicographically in date order, so plain string
    /// `min`/`max` double as date comparisons here.
    private static func tighten(_ existing: String?, _ candidate: String, by combine: (String, String) -> String) -> String {
        guard let existing else { return candidate }
        return combine(existing, candidate)
    }

    /// Parses `value` as an `on`/`before`/`after` date-range and, if valid, tightens
    /// `query`'s bound accordingly (see `apply`) — returning whether it was valid. Shared by
    /// `parse` (where an invalid value falls back to free text) and
    /// `SearchQuery.from(tokens:freeText:)` (where a date token's value is already
    /// known-valid, since promotion/suggestion only ever create a date token once its value
    /// has passed this same check).
    @discardableResult
    static func applyDateTag(_ tag: String, value: String, to query: inout SearchQuery) -> Bool {
        guard let range = dateRange(for: value) else { return false }
        apply(range, kind: tag, to: &query)
        return true
    }

    /// Whether `value` parses as one of the three valid date forms (`yyyy`, `yyyy-MM`,
    /// `yyyy-MM-dd`) — exposed so `SearchToken.promote`/`SearchSuggestions` can decide
    /// whether a typed date tag is promotable, without duplicating `dateRange`'s parsing
    /// rules.
    static func isValidDateValue(_ value: String) -> Bool {
        dateRange(for: value) != nil
    }

    // MARK: - Country normalisation

    /// Resolves a raw `country:` token to an uppercased ISO 3166-1 alpha-3 code: an exact
    /// (case-insensitive) alpha-3 match wins outright; failing that, a 2-letter value is
    /// reverse-looked-up against `CountryFlags`' alpha-2 values; failing that, `raw` is
    /// treated as a country NAME and matched against `Locale`'s localized region names (both
    /// the current locale and `en_US`, so this works regardless of device language); if
    /// nothing matches, `raw.uppercased()` is returned as-is so the filter still round-trips
    /// something recognisable rather than silently dropping the token.
    static func normalisedCountryCode(_ raw: String) -> String {
        let upper = raw.uppercased()

        if CountryFlags.alpha3ToAlpha2.keys.contains(upper) {
            return upper
        }

        if upper.count == 2, let alpha3 = CountryFlags.alpha3ToAlpha2.first(where: { $0.value == upper })?.key {
            return alpha3
        }

        for (alpha3, alpha2) in CountryFlags.alpha3ToAlpha2 {
            if let name = Locale.current.localizedString(forRegionCode: alpha2), name.caseInsensitiveCompare(raw) == .orderedSame {
                return alpha3
            }
            if let name = Locale(identifier: "en_US").localizedString(forRegionCode: alpha2), name.caseInsensitiveCompare(raw) == .orderedSame {
                return alpha3
            }
        }

        return upper
    }

    /// The display name for an ISO 3166-1 alpha-3 code — the reverse of
    /// `normalisedCountryCode`'s name→code matching, used to show a friendly name on a
    /// promoted/suggested `country` pill instead of its raw alpha-3 value. Tries the current
    /// locale first, falling back to `en_US`; `nil` if `code` isn't a recognized alpha-3.
    static func countryName(forAlpha3 code: String) -> String? {
        guard let alpha2 = CountryFlags.alpha3ToAlpha2[code.uppercased()] else { return nil }
        return Locale.current.localizedString(forRegionCode: alpha2)
            ?? Locale(identifier: "en_US").localizedString(forRegionCode: alpha2)
    }
}
