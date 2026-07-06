import CoreLocation

/// One rendered map pin: every element whose card sits at exactly the same coordinate.
/// Cards catalogued against the same place (same city lookup, say) land on one pin whose
/// popover lists them all, instead of a stack of indistinguishable overlapping pins.
struct MapPinGroup<Element> {
    var coordinate: CLLocationCoordinate2D
    var elements: [Element]
}

extension MapPinGroup: Identifiable {
    var id: String { "\(coordinate.latitude),\(coordinate.longitude)" }
}

enum MapPinGrouping {
    /// Groups elements sharing the exact same coordinate (equal `Double` pairs — this is
    /// deliberately not a distance/cluster threshold) into one pin each. Elements without
    /// a coordinate are dropped; both group order and each group's element order preserve
    /// the input's first-seen order.
    static func groups<Element>(
        of elements: [Element],
        coordinate: (Element) -> CLLocationCoordinate2D?
    ) -> [MapPinGroup<Element>] {
        var order: [CoordinateKey] = []
        var byKey: [CoordinateKey: MapPinGroup<Element>] = [:]

        for element in elements {
            guard let coordinate = coordinate(element) else { continue }
            let key = CoordinateKey(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = MapPinGroup(coordinate: coordinate, elements: [element])
            } else {
                byKey[key]?.elements.append(element)
            }
        }

        return order.compactMap { byKey[$0] }
    }

    private struct CoordinateKey: Hashable {
        var latitude: Double
        var longitude: Double
    }
}
