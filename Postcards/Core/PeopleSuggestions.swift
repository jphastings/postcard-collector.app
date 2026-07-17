import Foundation

/// Pure name-matching/ranking for "Create a Postcard"'s From/To/"Catalogued by" autocomplete —
/// mirrors `SearchSuggestions`' own fold/match-quality helpers (kept separate rather than
/// reused directly since this ranks whole `PersonRef`s for a name text field, not
/// `SearchToken`s for the search bar) so typing "cla" surfaces people you already know, not
/// string soup.
enum PeopleSuggestions {
    /// People whose name matches `query` (case/diacritic-insensitive prefix on the whole name
    /// or on any later word), ordered: `preferringRole` holders first (senders-first for a
    /// From field, recipients-first for To, collectors-first for "Catalogued by"), then match
    /// quality (a match at the start of the name beats a match on a later word), then name/uri
    /// for determinism. Every match is included regardless of role — `preferringRole` only
    /// orders results, it never filters them out.
    static func matches(for query: String, in people: [PersonRef], preferringRole: String, limit: Int = 8) -> [PersonRef] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return people
            .compactMap { person -> (PersonRef, MatchQuality)? in
                guard let name = person.name, !name.isEmpty, let quality = matchQuality(name: name, prefix: query) else {
                    return nil
                }
                return (person, quality)
            }
            .sorted { lhs, rhs in
                let lhsPreferred = lhs.0.roles.contains(preferringRole)
                let rhsPreferred = rhs.0.roles.contains(preferringRole)
                if lhsPreferred != rhsPreferred { return lhsPreferred }
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                let lhsName = lhs.0.name ?? "", rhsName = rhs.0.name ?? ""
                if lhsName != rhsName { return lhsName < rhsName }
                return (lhs.0.uri ?? "") < (rhs.0.uri ?? "")
            }
            .prefix(limit)
            .map(\.0)
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
        guard !foldedPrefix.isEmpty else { return nil }
        if foldedName.hasPrefix(foldedPrefix) { return .nameStart }
        let words = foldedName.split(whereSeparator: \.isWhitespace)
        guard words.dropFirst().contains(where: { $0.hasPrefix(foldedPrefix) }) else { return nil }
        return .wordStart
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
