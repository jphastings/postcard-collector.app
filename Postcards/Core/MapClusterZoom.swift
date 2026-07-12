import CoreGraphics
import CoreLocation
import MapKit

/// What tapping a multi-card pin should do: zoom the camera in on a region that would
/// actually pull its members apart on screen, or — if they're packed too tightly for that
/// to be worth doing — cycle through them instead (driven from
/// `CollectionMapView.pinClicked`, via `MapPinRotation`).
///
/// Pure and coordinate-only — no live `MapProxy` or screen geometry involved — so it's
/// testable without hosting a map: it bounds the members' OWN coordinates (not the
/// cluster's shared centroid) to decide the region's SPAN and whether zooming is even
/// worth doing, comparing the padded box's corner-to-corner distance against
/// `minimumUsefulSpanMeters`. Below that, even a tight, close-in camera wouldn't
/// meaningfully separate the members — it would sit closer than makes sense for browsing
/// a postcard collection, and the next settle's clustering would likely just re-merge
/// them anyway — so cycling serves the user better than reframing to a view that's barely
/// different from the current one. Identical coordinates are the limit case (zero span)
/// and always fall into `.cycle`: no camera, however tight, ever splits a stack sitting on
/// one exact point.
///
/// The resulting camera, when it does zoom, is always CENTRED ON THE PIN'S OWN DISPLAYED
/// COORDINATE (its cluster's centroid — see `MapPinGroup.coordinate`), not the members'
/// bounding-box centre: the tap originates from that exact pin, so re-centring on the
/// members' box instead would visibly jump the camera away from the spot the user just
/// tapped. The span is still sized from the members' own spread, just measured as each
/// axis's furthest deviation FROM that centre (doubled, since the centre isn't necessarily
/// in the middle of the members), so the recentred region still contains every member.
///
/// That "contains every member" sizing only ever guarantees the box's own two EXTREME
/// members end up apart — nothing about it relates to the members BETWEEN those extremes.
/// With exactly two members those are the same pair, so it's always sufficient; with three
/// or more, the box can easily enclose a tightly-packed sub-group that's nowhere near its
/// extremes, and padding the OUTER span alone does nothing to pull THOSE members apart —
/// the next settle's screen-space reclustering (44pt, see `MapPinClustering`) would just
/// re-merge them right back into one pin, making the zoom look like it did nothing. See
/// `regionGuaranteeingMemberSeparation` for the fix: it tightens the region, when needed,
/// around whichever pair of DISTINCT members sits closest together, so every member has a
/// real shot at separating rather than only the two furthest apart.
enum MapClusterZoom {
    /// Extra headroom added on each side of the members' span from the pin's centre, as a
    /// fraction of that span — mirrors `MapRegionFitting.paddingFraction`'s role, tuned a
    /// touch larger since this box can be tiny and benefits from more relative breathing
    /// room.
    static let paddingFraction: Double = 0.3
    /// Below this corner-to-corner span, zooming in on the members isn't a useful camera
    /// move (see the type's doc comment).
    static let minimumUsefulSpanMeters: CLLocationDistance = 5_000
    /// Degrees-floor for an axis with no spread at all (e.g. every member shares a
    /// latitude exactly), so the padded region is never degenerate on that axis.
    static let minimumAxisSpanDegrees: Double = 0.01
    /// The on-screen gap the tightest pair of DISTINCT members should clear once the
    /// camera settles — comfortably past `MapPinClustering.defaultThresholdPoints` (with
    /// the same relative breathing room as `paddingFraction`) so the very next settle's
    /// reclustering doesn't immediately merge them straight back into one pin.
    static let minimumMemberSeparationPoints: CGFloat = MapPinClustering.defaultThresholdPoints * (1 + paddingFraction)
    /// A deliberately conservative floor for the smallest map pane this zoom could ever
    /// render into, used only to size the WORST-CASE guarantee in
    /// `regionGuaranteeingMemberSeparation`. Keeping this a documented constant rather than
    /// threading a live `MapProxy`/viewport size through keeps the type pure and testable
    /// (see the type's doc comment); picked narrow enough to hold on any window or screen
    /// this map would realistically render in, but wide enough that an ordinarily-spread
    /// cluster (members already several screen-clusters' worth apart) never gets tightened
    /// unnecessarily — this only ever engages for a genuinely tight sub-group.
    static let assumedMinimumPaneSidePoints: CGFloat = 500

    enum Decision {
        case zoom(MKCoordinateRegion)
        case cycle
    }

    /// - Parameters:
    ///   - coordinates: The cluster members' own coordinates — used only to size the
    ///     region's span (see the type's doc comment).
    ///   - center: The pin's own displayed coordinate (its cluster's centroid) — the
    ///     camera always recentres here, never on the members' bounding-box centre.
    static func decision(for coordinates: [CLLocationCoordinate2D], centeredOn center: CLLocationCoordinate2D) -> Decision {
        guard let box = BoundingBox(of: coordinates) else { return .cycle }
        let span = CLLocation(latitude: box.minLatitude, longitude: box.minLongitude)
            .distance(from: CLLocation(latitude: box.maxLatitude, longitude: box.maxLongitude))
        guard span >= minimumUsefulSpanMeters else { return .cycle }
        let region = box.paddedRegion(centeredOn: center, paddingFraction: paddingFraction, minimumAxisSpanDegrees: minimumAxisSpanDegrees)
        return .zoom(regionGuaranteeingMemberSeparation(of: region, for: coordinates))
    }

    /// Tightens `region` (uniformly, about its own centre — `center` never moves) just
    /// enough that the closest pair of DISTINCT member coordinates would land more than
    /// `minimumMemberSeparationPoints` apart on screen, assuming a pane no smaller than
    /// `assumedMinimumPaneSidePoints` across. A no-op when the box-fit region already
    /// clears that bar (true for every two-member cluster, and for most larger ones whose
    /// members are reasonably evenly spread — see the type's doc comment for when it
    /// isn't).
    ///
    /// Exact-coordinate duplicates are excluded from "closest pair" — they're the designed
    /// exception that never splits (see `MapPinClustering`), so they must never drive this
    /// tighter; a cluster with no distinct pair at all (shouldn't happen here, since
    /// `decision` already turned an all-identical cluster into `.cycle`) leaves the region
    /// untouched.
    ///
    /// Trade-off, deliberate: tightening can push far-flung members outside the visible
    /// frame. That's fine — off-screen members simply reappear as their own singleton pin
    /// once the settle reclusters (`MapPinClustering.clusters` already treats an
    /// unprojectable member as its own singleton) — favouring an actual disaggregation of
    /// the tight sub-group over an all-encompassing view that would just re-merge everyone
    /// right back together.
    static func regionGuaranteeingMemberSeparation(of region: MKCoordinateRegion, for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        var closestDistinctPairMeters: CLLocationDistance?
        for i in coordinates.indices {
            for j in (i + 1)..<coordinates.count {
                let a = coordinates[i]
                let b = coordinates[j]
                guard a.latitude != b.latitude || a.longitude != b.longitude else { continue }
                let distance = CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                closestDistinctPairMeters = min(closestDistinctPairMeters ?? distance, distance)
            }
        }
        guard let closestDistinctPairMeters else { return region }

        // The metres a degree of latitude/longitude spans at this centre — matches how
        // MapKit itself renders a region: both axes share one points-per-metre scale
        // (so circles stay circles), bound by whichever axis needs MORE zoom-out to fit —
        // i.e. whichever axis covers MORE metres, assuming a roughly square pane.
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = 111_320.0 * cos(region.center.latitude * .pi / 180)
        let regionWidthMeters = region.span.longitudeDelta * metersPerDegreeLongitude
        let regionHeightMeters = region.span.latitudeDelta * metersPerDegreeLatitude
        let bindingAxisMeters = max(regionWidthMeters, regionHeightMeters)
        guard bindingAxisMeters > 0 else { return region }

        let predictedSeparationPoints = closestDistinctPairMeters / bindingAxisMeters * assumedMinimumPaneSidePoints
        guard predictedSeparationPoints < minimumMemberSeparationPoints else { return region }

        let shrinkFactor = predictedSeparationPoints / minimumMemberSeparationPoints
        return MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(
                latitudeDelta: max(region.span.latitudeDelta * shrinkFactor, minimumAxisSpanDegrees),
                longitudeDelta: max(region.span.longitudeDelta * shrinkFactor, minimumAxisSpanDegrees)
            )
        )
    }

    private struct BoundingBox {
        var minLatitude: Double
        var maxLatitude: Double
        var minLongitude: Double
        var maxLongitude: Double

        init?(of coordinates: [CLLocationCoordinate2D]) {
            guard !coordinates.isEmpty else { return nil }
            let latitudes = coordinates.map(\.latitude)
            let longitudes = coordinates.map(\.longitude)
            minLatitude = latitudes.min()!
            maxLatitude = latitudes.max()!
            minLongitude = longitudes.min()!
            maxLongitude = longitudes.max()!
        }

        /// Sized from each axis's furthest member deviation FROM `center` (not from this
        /// box's own midpoint), doubled to cover both sides symmetrically around `center` —
        /// so every member stays inside the region despite it being recentred away from
        /// the members' own bounding-box centre.
        func paddedRegion(
            centeredOn center: CLLocationCoordinate2D,
            paddingFraction: Double,
            minimumAxisSpanDegrees: Double
        ) -> MKCoordinateRegion {
            let latitudeDeviation = max(abs(maxLatitude - center.latitude), abs(minLatitude - center.latitude))
            let longitudeDeviation = max(abs(maxLongitude - center.longitude), abs(minLongitude - center.longitude))
            let latitudeDelta = max(latitudeDeviation * 2 * (1 + paddingFraction), minimumAxisSpanDegrees)
            let longitudeDelta = max(longitudeDeviation * 2 * (1 + paddingFraction), minimumAxisSpanDegrees)
            return MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            )
        }
    }
}
