import Foundation

/// Mail-style autocomplete over the search bar's currently-typed fragment: pure functions
/// only (no UI, no I/O) so they're trivially unit-testable — the caller supplies whatever
/// `PersonRef`s are in scope (a collection's `people(inCollectionAt:)` or the library's
/// `libraryPeople()`) and gets back candidate `SearchToken`s to render as tappable rows.
enum SearchSuggestions {
    /// Suggestions for the text currently in the search bar, considering only its trailing
    /// (still-being-typed) fragment — the part after the last whitespace, respecting an open
    /// quote. `existingTokens` are the pills already active, so a suggestion that duplicates
    /// one of them is dropped rather than offered again.
    ///
    /// - A fragment shaped `tag:partial` for a person tag suggests matching people AS THAT
    ///   tag only: `from:`/`to:`/`collector:` restrict to people who've held that exact
    ///   role; `with:` matches people who've held either `from` or `to`.
    /// - A fragment shaped `country:partial` suggests matching countries by name (or code).
    /// - A fragment shaped `on:`/`before:`/`after:` with a complete, valid date suggests that
    ///   date's own token (so the user can tap to promote it) — invalid/incomplete dates
    ///   suggest nothing.
    /// - A plain partial (≥2 characters, no tag prefix) suggests, per matching person, one
    ///   token per role they're eligible for — From/To/With/Collected by, in that order —
    ///   ordered overall by name-match quality then role order, followed by any matching
    ///   country names.
    static func suggestions(
        for text: String,
        people: [PersonRef],
        existingTokens: [SearchToken] = [],
        limit: Int = 8
    ) -> [SearchToken] {
        let fragment = trailingFragment(of: text)
        guard !fragment.isEmpty else { return [] }

        let candidates: [SearchToken]
        if let (kind, partial) = splitFragmentTag(fragment) {
            candidates = taggedFragmentSuggestions(kind: kind, partial: partial, people: people)
        } else if fragment.count >= 2 {
            candidates = plainFragmentSuggestions(fragment: fragment, people: people)
        } else {
            candidates = []
        }

        let existingIDs = Set(existingTokens.map(\.id))
        return Array(candidates.filter { !existingIDs.contains($0.id) }.prefix(limit))
    }

    // MARK: - Trailing fragment

    /// The fragment of `text` currently being typed — the last whitespace-separated word,
    /// respecting an open quote (so a still-open `tag:"Claire Sm` fragment keeps its
    /// embedded space). Reuses `SearchQuery`'s own tokenizer (rather than re-implementing
    /// quote handling) for exactly the fragment `SearchToken.promote(from:)` would leave as
    /// "still mid-typing" — but returns "" once `text` ends in whitespace, since the user has
    /// then started a new (as yet empty) word.
    private static func trailingFragment(of text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return "" }
        return SearchQuery.tokenize(text).last ?? ""
    }

    /// Splits a fragment into `(kind, partial)` if it starts with a recognized tag followed
    /// by a colon — unlike `SearchQuery.splitTag`, `partial` MAY be empty (`"from:"` is a
    /// valid, if unfiltered, fragment while the user is still typing the person's name).
    private static func splitFragmentTag(_ fragment: String) -> (kind: SearchToken.Kind, partial: String)? {
        guard let colonIndex = fragment.firstIndex(of: ":") else { return nil }
        guard let kind = SearchToken.Kind(rawValue: fragment[fragment.startIndex..<colonIndex].lowercased()) else {
            return nil
        }
        return (kind, String(fragment[fragment.index(after: colonIndex)...]))
    }

    // MARK: - Tagged fragment (`tag:partial`)

    private static func taggedFragmentSuggestions(
        kind: SearchToken.Kind, partial: String, people: [PersonRef]
    ) -> [SearchToken] {
        switch kind {
        case .from:
            return personSuggestions(people: people, partial: partial, kind: .from) { $0.roles.contains("from") }
        case .to:
            return personSuggestions(people: people, partial: partial, kind: .to) { $0.roles.contains("to") }
        case .collector:
            return personSuggestions(people: people, partial: partial, kind: .collector) { $0.roles.contains("collector") }
        case .with:
            return personSuggestions(people: people, partial: partial, kind: .with) {
                $0.roles.contains("from") || $0.roles.contains("to")
            }
        case .country:
            return countrySuggestions(partial: partial)
        case .on, .before, .after:
            guard SearchQuery.isValidDateValue(partial) else { return [] }
            return [SearchToken(kind: kind, display: partial, value: partial)]
        }
    }

    // MARK: - Plain fragment (no tag prefix)

    /// One token per role a matching person is eligible for (From/To/With/Collected by, in
    /// that order), for every matching person in match-quality order, followed by matching
    /// country names.
    private static func plainFragmentSuggestions(fragment: String, people: [PersonRef]) -> [SearchToken] {
        var results: [SearchToken] = []
        for person in matchingPeople(people: people, partial: fragment) {
            if person.roles.contains("from") { results.append(token(for: person, kind: .from)) }
            if person.roles.contains("to") { results.append(token(for: person, kind: .to)) }
            if person.roles.contains("from") || person.roles.contains("to") {
                results.append(token(for: person, kind: .with))
            }
            if person.roles.contains("collector") { results.append(token(for: person, kind: .collector)) }
        }
        results.append(contentsOf: countrySuggestions(partial: fragment))
        return results
    }

    // MARK: - People

    private static func personSuggestions(
        people: [PersonRef], partial: String, kind: SearchToken.Kind, roleFilter: (PersonRef) -> Bool
    ) -> [SearchToken] {
        matchingPeople(people: people.filter(roleFilter), partial: partial).map { token(for: $0, kind: kind) }
    }

    /// People whose name matches `partial` (any word, case/diacritic-insensitive prefix),
    /// ordered by match quality (a match at the start of the full name beats a match on a
    /// later word) and then alphabetically by name/uri for determinism.
    private static func matchingPeople(people: [PersonRef], partial: String) -> [PersonRef] {
        people
            .compactMap { person -> (PersonRef, MatchQuality)? in
                guard let name = person.name, !name.isEmpty, let quality = matchQuality(name: name, prefix: partial) else {
                    return nil
                }
                return (person, quality)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let lhsName = lhs.0.name ?? "", rhsName = rhs.0.name ?? ""
                if lhsName != rhsName { return lhsName < rhsName }
                return (lhs.0.uri ?? "") < (rhs.0.uri ?? "")
            }
            .map(\.0)
    }

    /// A person token's value is their URI when they have one, else their name — so a
    /// promoted/accepted pill searches the more precise identifier when it's available.
    private static func token(for person: PersonRef, kind: SearchToken.Kind) -> SearchToken {
        let name = person.name ?? ""
        let value = (person.uri?.isEmpty == false) ? person.uri! : name
        return SearchToken(kind: kind, display: name, value: value)
    }

    private enum MatchQuality: Int, Comparable {
        case nameStart, wordStart
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// `nil` if `name` doesn't match `prefix` at all; `.nameStart` if `prefix` prefixes the
    /// whole (folded) name, else `.wordStart` if it prefixes some later word.
    private static func matchQuality(name: String, prefix: String) -> MatchQuality? {
        let foldedName = fold(name)
        let foldedPrefix = fold(prefix)
        guard !foldedPrefix.isEmpty else { return .wordStart }
        if foldedName.hasPrefix(foldedPrefix) { return .nameStart }
        let words = foldedName.split(whereSeparator: \.isWhitespace)
        guard words.dropFirst().contains(where: { $0.hasPrefix(foldedPrefix) }) else { return nil }
        return .wordStart
    }

    // MARK: - Countries

    /// Countries whose (localized) name, or alpha-3/alpha-2 code, prefix-matches `partial` —
    /// factors `SearchQuery.countryName(forAlpha3:)` (the reverse of
    /// `normalisedCountryCode`) rather than re-deriving country names here.
    private static func countrySuggestions(partial: String) -> [SearchToken] {
        let foldedPartial = fold(partial)
        return CountryFlags.alpha3ToAlpha2
            .compactMap { alpha3, alpha2 -> (alpha3: String, name: String)? in
                guard let name = SearchQuery.countryName(forAlpha3: alpha3) else { return nil }
                guard fold(name).hasPrefix(foldedPartial)
                    || alpha3.lowercased().hasPrefix(partial.lowercased())
                    || alpha2.lowercased().hasPrefix(partial.lowercased()) else { return nil }
                return (alpha3, name)
            }
            .sorted { $0.name < $1.name }
            .map { SearchToken(kind: .country, display: $0.name, value: $0.alpha3) }
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
