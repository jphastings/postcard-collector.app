import Foundation

/// Pure string composition for `LocationSearchField`: turns a selected search result's
/// placemark fields into the `locationName` autofilled onto the card — broad and readable
/// (a town + country, e.g. "Turin, Italy") rather than a full street address, since that's
/// what's useful for browsing/search later. Kept in Core, taking plain strings rather than
/// `CLPlacemark`, so it's testable without MapKit.
enum LocationSearchNaming {
    /// Prefers `locality` (falling back to `administrativeArea` when there's no city, e.g. a
    /// search result that only resolved to a state/region) combined with `country`; degrades
    /// field-by-field as they go missing, all the way down to `fallbackTitle` — the search
    /// completion's own title — when the placemark has nothing usable at all.
    static func displayName(
        locality: String?,
        administrativeArea: String?,
        country: String?,
        fallbackTitle: String
    ) -> String {
        let region = nonEmpty(locality) ?? nonEmpty(administrativeArea)
        let country = nonEmpty(country)

        switch (region, country) {
        case (let region?, let country?): return "\(region), \(country)"
        case (let region?, nil): return region
        case (nil, let country?): return country
        case (nil, nil): return fallbackTitle
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
