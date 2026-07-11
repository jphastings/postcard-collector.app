import Foundation

/// One search-bar "pill": something the user picked (by typing a complete tag expression or
/// accepting a suggestion) that DISPLAYS a friendly name but SEARCHES a different underlying
/// value — e.g. a person pill shows "Claire" but searches her `uri` when she has one, and a
/// country pill shows "Spain" but searches `"ESP"`. Mirrors the tag vocabulary
/// `SearchQuery.parse` already recognizes.
struct SearchToken: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case from, to, with, collector, country, on, before, after
    }

    var kind: Kind
    var display: String
    var value: String

    /// `kind` + `value` (not `display`) identify a token — two people who happen to share a
    /// display name but have different `uri`s (or a name-only person vs. a URI'd one) are
    /// different tokens, and re-accepting the same suggestion twice is a no-op.
    var id: String { "\(kind.rawValue):\(value)" }

    /// A human label for the pill itself, matching `SearchQuery`'s tag vocabulary — e.g.
    /// "From Claire", "Collected by Claire", "Country Spain", "On 2024-05".
    var pillLabel: String {
        switch kind {
        case .from: return "From \(display)"
        case .to: return "To \(display)"
        case .with: return "With \(display)"
        case .collector: return "Collected by \(display)"
        case .country: return "Country \(display)"
        case .on: return "On \(display)"
        case .before: return "Before \(display)"
        case .after: return "After \(display)"
        }
    }

    // MARK: - Promotion (typed text -> tokens)

    /// Scans `text` for COMPLETE tag expressions (`tag:value` or `tag:"quoted value"`) and
    /// converts each into a token, returning the tokens found plus whatever text is left
    /// over — still-plain-text words, and any tag expression that didn't qualify for
    /// promotion.
    ///
    /// A tag expression only counts as "complete" if it's followed by whitespace: the very
    /// last whitespace-separated fragment of `text` is never promoted unless `text` itself
    /// ends in whitespace, since that trailing fragment might still be mid-typing (the user
    /// could be about to add more characters, or close a quote, right after what already
    /// looks like a valid value). This is a deliberate design choice — matching how
    /// Mail.app only turns a token into a pill once you've moved past it, not while your
    /// cursor is still inside it.
    ///
    /// Person tags (from/to/with/collector) and `country` always promote once complete —
    /// `country`'s value is normalised to an alpha-3 code (`SearchQuery.normalisedCountryCode`)
    /// and its display name resolved via the reverse lookup where possible, falling back to
    /// the as-typed text otherwise. Date tags (on/before/after) only promote when the value
    /// is a valid `yyyy`/`yyyy-MM`/`yyyy-MM-dd` date — an unparseable date stays as text, so
    /// the user can keep correcting it inline.
    static func promote(from text: String) -> (tokens: [SearchToken], remainder: String) {
        let fragments = SearchQuery.tokenize(text)
        guard !fragments.isEmpty else { return ([], text) }

        // Whether the LAST fragment was itself terminated by whitespace (vs. cut off by the
        // end of `text`) — see the doc comment above.
        let trailingFragmentIsComplete = text.last?.isWhitespace ?? false

        var tokens: [SearchToken] = []
        var remainderFragments: [String] = []

        for (index, fragment) in fragments.enumerated() {
            let isTrailing = index == fragments.count - 1
            guard !isTrailing || trailingFragmentIsComplete,
                  let (tag, value) = SearchQuery.splitTag(fragment),
                  let kind = Kind(rawValue: tag) else {
                remainderFragments.append(requoted(fragment))
                continue
            }

            switch kind {
            case .from, .to, .with, .collector:
                tokens.append(SearchToken(kind: kind, display: value, value: value))
            case .country:
                let code = SearchQuery.normalisedCountryCode(value)
                let display = SearchQuery.countryName(forAlpha3: code) ?? value
                tokens.append(SearchToken(kind: kind, display: display, value: code))
            case .on, .before, .after:
                if SearchQuery.isValidDateValue(value) {
                    tokens.append(SearchToken(kind: kind, display: value, value: value))
                } else {
                    remainderFragments.append(requoted(fragment))
                }
            }
        }

        return (tokens, remainderFragments.joined(separator: " "))
    }

    /// Re-adds quoting around a fragment being put back into free text, if it contains
    /// whitespace — otherwise a dequoted value like `"Claire Smith"`'s `Claire Smith` would
    /// re-tokenize as two separate words the next time this text is parsed. Mirrors
    /// `CardInfoPanel.presetValue`'s "quote only if it needs it" rule.
    private static func requoted(_ fragment: String) -> String {
        guard fragment.contains(where: \.isWhitespace) else { return fragment }
        return "\"\(fragment)\""
    }
}

extension SearchQuery {
    /// Assembles a `SearchQuery` from active pill tokens plus whatever free text remains in
    /// the search bar. `freeText` still goes through the ordinary tag parser (so a
    /// not-yet-promoted `tag:value` the user is mid-typing keeps working), and each token
    /// then folds its value into the matching field: person kinds append to their array,
    /// `country` appends its (already alpha-3) value, and date kinds reuse the same
    /// tightening logic `parse` uses for `on`/`before`/`after`.
    static func from(tokens: [SearchToken], freeText: String) -> SearchQuery {
        var query = parse(freeText)
        for token in tokens {
            switch token.kind {
            case .from: query.from.append(token.value)
            case .to: query.to.append(token.value)
            case .with: query.with.append(token.value)
            case .collector: query.collector.append(token.value)
            case .country: query.country.append(token.value)
            case .on, .before, .after:
                applyDateTag(token.kind.rawValue, value: token.value, to: &query)
            }
        }
        return query
    }
}
