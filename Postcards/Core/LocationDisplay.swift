/// Pure decision logic for `CardInfoPanel`'s "Location" section, extracted from the view so
/// it's unit-testable without pulling in SwiftUI/MapKit: a name-only location shows text but
/// no map; a location with neither a name nor coordinates shows nothing at all.
enum LocationDisplay {
    /// Whether the "Location" section should appear at all.
    static func showsSection(for location: Location) -> Bool {
        location.name != nil || hasCoordinates(location)
    }

    /// Whether the section's map (a `Marker` at the card's coordinate) should render —
    /// requires BOTH latitude and longitude; a name alone must show text only, never a map
    /// with a made-up or default coordinate.
    static func hasCoordinates(_ location: Location) -> Bool {
        location.latitude != nil && location.longitude != nil
    }
}
