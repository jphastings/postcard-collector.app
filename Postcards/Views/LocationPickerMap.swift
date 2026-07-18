import MapKit
import SwiftUI

/// The manual half of "Create a Postcard"'s Location section: a compact map that places/moves a
/// marker on tap and writes straight into the two bound coordinate fields — no location
/// permission needed, since (like `LocationSearchField`) this never touches `CLLocationManager`.
/// A chosen search result recenters the map on its own coordinate (see `recenterTrigger`); a
/// manual tap only moves the pin, never the camera, so tapping near an edge doesn't jump the map
/// out from under the next tap.
struct LocationPickerMap: View {
    @Binding var latitude: Double?
    @Binding var longitude: Double?
    /// Bumped by `LocationSearchField` whenever a search result overwrites the coordinate.
    /// `LocationPickerMap` recenters on this signal rather than on `latitude`/`longitude`
    /// directly, because a manual map tap writes those same two fields too and must NOT
    /// trigger a camera jump — see `.task(id:)` below.
    let recenterTrigger: Int
    /// The region to recenter on when `recenterTrigger` fires — sized to the search result's
    /// granularity (street vs. city vs. region vs. country) by `LocationSearchField`, either
    /// straight from MapKit's own `boundingRegion` or a `LocationZoom` heuristic. Read only at
    /// the moment the trigger fires, same as `recenterTrigger` itself being a plain (not
    /// `@Binding`) value here.
    let recenterRegion: MKCoordinateRegion?

    @State private var cameraPosition: MapCameraPosition = .automatic

    /// Only used if a search result's coordinate somehow arrives with no `recenterRegion` —
    /// belt-and-braces, since `LocationSearchField` always sets both together.
    private static let fallbackSpan = MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)

    private var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    if let coordinate {
                        Marker("Location", coordinate: coordinate)
                    }
                }
                .onTapGesture { point in
                    guard let tapped = proxy.convert(point, from: .local) else { return }
                    latitude = tapped.latitude
                    longitude = tapped.longitude
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if coordinate != nil {
                Button("Remove pin", role: .destructive) {
                    latitude = nil
                    longitude = nil
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
        }
        .task(id: recenterTrigger) { recenter() }
    }

    private func recenter() {
        guard let coordinate else { return }
        let region = recenterRegion ?? MKCoordinateRegion(center: coordinate, span: Self.fallbackSpan)
        withAnimation(.easeInOut) {
            cameraPosition = .region(region)
        }
    }
}
