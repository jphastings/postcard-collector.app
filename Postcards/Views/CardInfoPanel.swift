import CoreLocation
import MapKit
import SwiftUI

/// The metadata side panel for a card: sheet on iOS, inspector on macOS (see
/// `CardDetailView`). Shows descriptions, sender/recipient, sent date, a map when
/// coordinates are present, the location's flag, transcriptions, and cataloguing context.
struct CardInfoPanel: View {
    let summary: CardSummary
    let metadata: PostcardMetadata
    /// Called with a preset like `"from:Claire"` or `"collector:\"Claire Smith\""` when a
    /// person row's menu is used — `CardDetailView` forwards this straight to its
    /// `SearchRequest`.
    let onSearchPreset: (String) -> Void

    @State private var cameraPosition: MapCameraPosition
    @State private var showsMapResetButton = false
    // The map's very first camera update is MapKit settling into `initialMapRegion` itself,
    // not a user pan/zoom — this skips flagging that one as "moved".
    @State private var hasSeenInitialCameraSettle = false

    // Computed once in `init` (rather than as a property derived from `metadata` on every body
    // evaluation) so the reset button always animates back to the exact region the map started
    // at, not a freshly recomputed one. `CardDetailView` gives this view a fresh identity per
    // card (`.id(reference.id)`), so a new card always gets a new instance — and a new instance
    // of this state — rather than reusing a previous card's camera position.
    private let initialMapRegion: MKCoordinateRegion?

    init(summary: CardSummary, metadata: PostcardMetadata, onSearchPreset: @escaping (String) -> Void) {
        self.summary = summary
        self.metadata = metadata
        self.onSearchPreset = onSearchPreset

        let location = metadata.location
        if LocationDisplay.showsSection(for: location), LocationDisplay.hasCoordinates(location),
           let latitude = location.latitude, let longitude = location.longitude {
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                latitudinalMeters: 50_000, longitudinalMeters: 50_000
            )
            initialMapRegion = region
            _cameraPosition = State(initialValue: .region(region))
        } else {
            initialMapRegion = nil
            _cameraPosition = State(initialValue: .automatic)
        }
    }

    var body: some View {
        Form {
            if let sentOn = metadata.sentOn ?? summary.sentOn {
                LabeledContent("Sent") {
                    Text(sentOn.date.formatted(date: .long, time: .omitted))
                }
            }

            Section("From & to") {
                personRow(metadata.sender, label: "Sender", presets: .fromToWith)
                personRow(metadata.recipient, label: "Recipient", presets: .fromToWith)
            }

            if let location = displayableLocation {
                Section("Location") {
                    LabeledContent("Place") {
                        HStack(spacing: 6) {
                            if let flag = location.countryCode.flatMap(CountryFlags.flag(forAlpha3:)) {
                                Text(flag)
                            }
                            Text(location.name ?? "Unknown")
                        }
                    }

                    if LocationDisplay.hasCoordinates(location),
                       let latitude = location.latitude, let longitude = location.longitude {
                        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                        mapView(coordinate: coordinate, name: location.name ?? summary.name)
                    }
                }
            }

            sideSection(title: "Front", side: metadata.front)
            sideSection(title: "Back", side: metadata.back)

            if hasContext {
                Section("Context") {
                    if let description = metadata.context.description, !description.isEmpty {
                        Text(description)
                    }
                    personRow(metadata.context.author, label: "Catalogued by", presets: .collectorOnly)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(summary.name)
    }

    @ViewBuilder
    private func mapView(coordinate: CLLocationCoordinate2D, name: String) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                Marker(name, coordinate: coordinate)
            }
            .onMapCameraChange { context in
                guard let initialMapRegion else { return }
                guard hasSeenInitialCameraSettle else {
                    hasSeenInitialCameraSettle = true
                    return
                }
                showsMapResetButton = !context.region.isApproximately(initialMapRegion)
            }

            if showsMapResetButton {
                Button {
                    guard let initialMapRegion else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        cameraPosition = .region(initialMapRegion)
                    }
                    showsMapResetButton = false
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.footnote.weight(.semibold))
                        .padding(8)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
        .frame(height: 200)
        .listRowInsets(EdgeInsets())
    }

    private var displayableLocation: Location? {
        let location = metadata.location
        return LocationDisplay.showsSection(for: location) ? location : nil
    }

    private var hasContext: Bool {
        !(metadata.context.description ?? "").isEmpty || !(metadata.context.author.name ?? "").isEmpty
    }

    /// Which search-preset buttons a `personRow`'s menu offers: sender/recipient rows offer
    /// all three of from/to/with (regardless of which of the two this row actually is — a
    /// sender can just as easily be the subject of a "more WITH this person" search), while
    /// the "Catalogued by" row only ever makes sense as a `collector:` search.
    private enum PersonRowPresets {
        case fromToWith
        case collectorOnly
    }

    @ViewBuilder
    private func personRow(_ person: Person, label: String, presets: PersonRowPresets) -> some View {
        if let name = person.name, !name.isEmpty {
            LabeledContent(label) {
                Menu {
                    switch presets {
                    case .fromToWith:
                        presetButton(tag: "from", title: "More from \(name)", person: person)
                        presetButton(tag: "to", title: "More to \(name)", person: person)
                        presetButton(tag: "with", title: "More with \(name)", person: person)
                    case .collectorOnly:
                        presetButton(tag: "collector", title: "More collected by \(name)", person: person)
                    }
                    if let url = validURL(for: person) {
                        Divider()
                        contactLink(url: url, name: name)
                    }
                } label: {
                    Text(name)
                }
                #if os(macOS)
                // Inside a `Form` row, the default menu style renders as a full-width button;
                // borderless keeps it reading as an inline disclosure next to the label.
                .menuStyle(.borderlessButton)
                #endif
            }
        }
    }

    private func presetButton(tag: String, title: String, person: Person) -> some View {
        Button(title) {
            onSearchPreset("\(tag):\(presetValue(for: person))")
        }
    }

    /// The value half of a preset like `from:Claire` or `from:"Claire Smith"`: the person's
    /// URI when they have one that parses (used as-is — URIs don't normally contain
    /// whitespace, but the same quoting rule applies uniformly just in case), else their
    /// name; quoted with `"..."` only if it contains whitespace, since the parser's tokenizer
    /// needs that to keep a multi-word value as one token.
    private func presetValue(for person: Person) -> String {
        let raw = validURL(for: person) != nil ? (person.uri ?? "") : (person.name ?? "")
        guard raw.contains(where: \.isWhitespace) else { return raw }
        return "\"\(raw)\""
    }

    private func validURL(for person: Person) -> URL? {
        guard let uri = person.uri, !uri.isEmpty else { return nil }
        return URL(string: uri)
    }

    @ViewBuilder
    private func contactLink(url: URL, name: String) -> some View {
        if url.scheme?.lowercased() == "mailto" {
            Link("Email \(name)", destination: url)
        } else {
            Link(destination: url) {
                Text(visitLabel(for: url)).underline()
            }
        }
    }

    /// "Visit <host>" when the URL has one (the common case for `scheme://host/...` links);
    /// otherwise the raw URI with its scheme prefix trimmed off, so at least something
    /// readable shows instead of the scheme name alone.
    private func visitLabel(for url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            return "Visit \(host)"
        }
        var trimmed = url.absoluteString
        if let scheme = url.scheme {
            for prefix in ["\(scheme)://", "\(scheme):"] where trimmed.hasPrefix(prefix) {
                trimmed.removeFirst(prefix.count)
                break
            }
        }
        return "Visit \(trimmed)"
    }

    @ViewBuilder
    private func sideSection(title: String, side: Side) -> some View {
        let hasDescription = !(side.description ?? "").isEmpty
        let hasTranscription = !side.transcription.text.isEmpty

        if hasDescription || hasTranscription {
            Section(title) {
                if hasDescription, let description = side.description {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
                if hasTranscription {
                    Text(AnnotatedTextRenderer.attributedString(for: side.transcription))
                }
            }
        }
    }
}

private extension MKCoordinateRegion {
    /// Loose equality for deciding whether the user has panned/zoomed away from a starting
    /// region — exact equality would never match once MapKit's own settling nudges the camera
    /// by fractions of a degree.
    func isApproximately(_ other: MKCoordinateRegion, tolerance: CLLocationDegrees = 0.01) -> Bool {
        abs(center.latitude - other.center.latitude) < tolerance &&
        abs(center.longitude - other.center.longitude) < tolerance &&
        abs(span.latitudeDelta - other.span.latitudeDelta) < tolerance &&
        abs(span.longitudeDelta - other.span.longitudeDelta) < tolerance
    }
}
