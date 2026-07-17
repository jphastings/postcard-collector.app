import Foundation

/// Localized, sorted country list for UI pickers (e.g. the "Create a Postcard" country
/// dropdown), built from `CountryFlags.alpha3ToAlpha2` — the app's only country-code table.
enum CountryDirectory {
    struct Entry: Hashable, Sendable {
        let alpha3: String
        let displayName: String
        let flag: String?
    }

    /// Every country in `CountryFlags.alpha3ToAlpha2`, localized to the user's current locale
    /// and sorted by that localized name — the production list a country picker binds to.
    static let all: [Entry] = makeEntries(locale: .current)

    /// Locale-parameterized so tests can assert against a fixed, deterministic locale (`.current`
    /// would make assertions on exact display strings flaky depending on the test machine's
    /// locale) while `all` still gives the UI the user's actual locale.
    static func makeEntries(locale: Locale) -> [Entry] {
        CountryFlags.alpha3ToAlpha2.map { alpha3, alpha2 in
            let displayName = locale.localizedString(forRegionCode: alpha2) ?? alpha3
            return Entry(alpha3: alpha3, displayName: displayName, flag: CountryFlags.flag(forAlpha2: alpha2))
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}
