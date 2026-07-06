import CoreGraphics
import CoreLocation

/// One rendered map pin: every element whose card would draw at (or too close to) the same
/// place on screen at the current zoom. Cards catalogued against the same city land on one
/// pin whose popover lists them all, instead of a stack of indistinguishable overlapping
/// pins — and nearby-but-distinct places merge or split as the camera zooms (see
/// `MapPinClustering`).
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

/// Zoom-aware clustering in SCREEN space: pins whose rendered positions would overlap at
/// the current camera merge into one group pin, and split back apart as zooming in spreads
/// them past the threshold. Exact-coordinate duplicates are the degenerate case (distance
/// 0 at every zoom) — they simply never split.
enum MapPinClustering {
    /// One pin's touch-target diameter: two pin centres closer than this on screen are
    /// effectively on top of each other.
    static let defaultThresholdPoints: CGFloat = 44

    /// Clusters elements by pairwise screen distance ≤ `threshold`, merged TRANSITIVELY
    /// (union-find): A near B and B near C puts all three in one cluster even when A and C
    /// are far apart — chosen because the alternative (strict pairwise cliques) can't
    /// partition consistently, and a chain of overlapping pins is unreadable as separate
    /// markers anyway. The threshold is inclusive: exactly `threshold` apart still merges.
    ///
    /// Deterministic and order-stable: clusters appear in input order of their first
    /// member, and each cluster's elements keep input order. Elements without a screen
    /// point (unprojectable, e.g. off-screen at the current camera) stay as singletons —
    /// they aren't visible to overlap anything, and the next camera change re-clusters.
    static func clusters<Element>(
        of elements: [Element],
        threshold: CGFloat = defaultThresholdPoints,
        screenPoint: (Element) -> CGPoint?
    ) -> [[Element]] {
        let points = elements.map(screenPoint)
        var parent = Array(elements.indices)

        func root(of index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }

        for i in elements.indices {
            guard let a = points[i] else { continue }
            for j in (i + 1)..<elements.count {
                guard let b = points[j] else { continue }
                if hypot(a.x - b.x, a.y - b.y) <= threshold {
                    // Always attach the larger root under the smaller: every cluster's
                    // root is its first member in input order, keeping output stable.
                    let ri = root(of: i)
                    let rj = root(of: j)
                    if ri != rj {
                        parent[max(ri, rj)] = min(ri, rj)
                    }
                }
            }
        }

        var order: [Int] = []
        var byRoot: [Int: [Element]] = [:]
        for index in elements.indices {
            let r = root(of: index)
            if byRoot[r] == nil { order.append(r) }
            byRoot[r, default: []].append(elements[index])
        }
        return order.compactMap { byRoot[$0] }
    }

    /// A merged marker's display coordinate: the members' arithmetic-mean coordinate.
    /// Chosen over "first member's coordinate" because the marker stands for all of them —
    /// it should sit between the places, not on an arbitrary one. A flat average is fine
    /// at clustering scales (things close enough to overlap on screen are far from any
    /// meridian-wrapping or great-circle concerns).
    static func centroid(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !coordinates.isEmpty else { return nil }
        return CLLocationCoordinate2D(
            latitude: coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count),
            longitude: coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
        )
    }

    /// Every element's current cluster, keyed by element id, plus whether it's that
    /// cluster's REPRESENTATIVE — its first member in stable order. Only the representative
    /// draws a cluster's interactive content (tap target, hover tracking, name popover);
    /// every other member still needs its own group because the group's coordinate is the
    /// element's DISPLAY coordinate (see `CollectionMapView`'s doc comment).
    static func membership<Element: Identifiable>(
        of groups: [MapPinGroup<Element>]
    ) -> [Element.ID: (group: MapPinGroup<Element>, isRepresentative: Bool)] {
        var result: [Element.ID: (group: MapPinGroup<Element>, isRepresentative: Bool)] = [:]
        for group in groups {
            for (index, element) in group.elements.enumerated() {
                result[element.id] = (group, index == 0)
            }
        }
        return result
    }

    /// FLIP glide deltas for a membership change: every element is displayed at its
    /// group's coordinate (own coordinate when singleton, cluster centroid otherwise), so
    /// when reclustering moves an element from one group to another its pin JUMPS to the
    /// new geographic anchor — the returned delta is the screen-space vector (old display
    /// point − new display point, both projected at the SAME settled camera) that, applied
    /// as an initial `.offset` and animated to zero, makes the pin visually glide from
    /// where it stood to its new anchor instead.
    ///
    /// Only elements that actually moved get an entry: same display coordinate → no entry
    /// (nothing to glide); an element with no old group (fresh to the map) → no entry
    /// (appearing pins shouldn't fly in from anywhere); either endpoint unprojectable
    /// (off-screen) → no entry (no glide beats a wrong one). Kept pure — a plain
    /// projection closure rather than a live `MapProxy` — so the math is testable without
    /// hosting a map.
    static func flipDeltas<Element: Identifiable>(
        from oldGroups: [MapPinGroup<Element>],
        to newGroups: [MapPinGroup<Element>],
        projectedPoint: (CLLocationCoordinate2D) -> CGPoint?
    ) -> [Element.ID: CGSize] {
        let oldMembership = membership(of: oldGroups)
        var deltas: [Element.ID: CGSize] = [:]
        for group in newGroups {
            for element in group.elements {
                guard let old = oldMembership[element.id]?.group.coordinate else { continue }
                let new = group.coordinate
                guard old.latitude != new.latitude || old.longitude != new.longitude else { continue }
                guard let oldPoint = projectedPoint(old), let newPoint = projectedPoint(new) else { continue }
                deltas[element.id] = CGSize(width: oldPoint.x - newPoint.x, height: oldPoint.y - newPoint.y)
            }
        }
        return deltas
    }
}

/// A pin click always navigates; on a multi-card pin, successive clicks rotate through the
/// co-located cards.
enum MapPinRotation {
    /// Which element a pin click should open: the one AFTER `current` when `current` is in
    /// the group (wrapping around at the end), otherwise the group's first element. A
    /// single-element group therefore always yields that element; only an empty group
    /// yields `nil`.
    static func next<Element: Equatable>(in elements: [Element], after current: Element?) -> Element? {
        guard let current, let index = elements.firstIndex(of: current) else {
            return elements.first
        }
        return elements[(index + 1) % elements.count]
    }
}
