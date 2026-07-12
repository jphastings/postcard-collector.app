import CoreLocation
import MapKit
import SwiftUI

/// The metadata side panel for a card: sheet on iOS, inspector on macOS (see
/// `CardDetailView`). Shows descriptions, sender/recipient, sent date, a map when
/// coordinates are present, the location's flag, transcriptions, and cataloguing context.
struct CardInfoPanel: View {
    let summary: CardSummary
    let metadata: PostcardMetadata
    /// Called with a pill token (e.g. `from: Claire`) when a person row's menu is used —
    /// `CardDetailView` forwards this straight to its `SearchRequest`.
    let onSearchPreset: (SearchToken) -> Void

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

    init(summary: CardSummary, metadata: PostcardMetadata, onSearchPreset: @escaping (SearchToken) -> Void) {
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
            // Kept at the very top: the new section order (transcriptions, then from/to, …)
            // doesn't mention this row, and it was already leading the panel before the
            // restructure, so it stays put rather than being folded into a section below.
            if let sentOn = metadata.sentOn ?? summary.sentOn {
                LabeledContent("Sent") {
                    Text(sentOn.date.formatted(date: .long, time: .omitted))
                }
            }

            if hasFrontTranscription || hasBackTranscription {
                Section {
                    if hasFrontTranscription {
                        captionedBlock(caption: showsBothTranscriptions ? "front" : nil) {
                            Text(AnnotatedTextRenderer.attributedString(for: metadata.front.transcription))
                        }
                    }
                    if hasBackTranscription {
                        captionedBlock(caption: showsBothTranscriptions ? "back" : nil) {
                            Text(AnnotatedTextRenderer.attributedString(for: metadata.back.transcription))
                        }
                    }
                }
            }

            Section {
                personRow(metadata.sender, label: "From", presets: .sender)
                personRow(metadata.recipient, label: "To", presets: .recipient)
            }

            if let location = displayableLocation {
                Section {
                    LabeledContent("Sent from") {
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

            if hasContext {
                Section("Context") {
                    if let description = metadata.context.description, !description.isEmpty {
                        Text(description)
                    }
                    personRow(metadata.context.author, label: "Catalogued by", presets: .collectorOnly)
                }
            }

            if hasFrontDescription || hasBackDescription {
                Section("Alt text") {
                    if hasFrontDescription {
                        captionedBlock(caption: showsBothDescriptions ? "front" : nil) {
                            Text(metadata.front.description ?? "")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if hasBackDescription {
                        captionedBlock(caption: showsBothDescriptions ? "back" : nil) {
                            Text(metadata.back.description ?? "")
                                .foregroundStyle(.secondary)
                        }
                    }
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

    private var hasFrontTranscription: Bool { !metadata.front.transcription.text.isEmpty }
    private var hasBackTranscription: Bool { !metadata.back.transcription.text.isEmpty }
    private var showsBothTranscriptions: Bool { hasFrontTranscription && hasBackTranscription }

    private var hasFrontDescription: Bool { !(metadata.front.description ?? "").isEmpty }
    private var hasBackDescription: Bool { !(metadata.back.description ?? "").isEmpty }
    private var showsBothDescriptions: Bool { hasFrontDescription && hasBackDescription }

    /// Which search-preset buttons a `personRow`'s menu offers, and how they're worded: every
    /// row offers all three of from/to/with (a sender can just as easily be the subject of a
    /// "more WITH this person" search), but "More" only prefixes a preset the CURRENT card
    /// already matches — otherwise the button reads as a plain call to action, not a "more of
    /// the same". `.sender`/`.recipient` say which filter(s) that is for this row: the sender
    /// row already matches `from` and `with`, the recipient row already matches `to` and
    /// `with`. The "Catalogued by" row only ever makes sense as a `collector:` search, which
    /// always matches the current card, so it's always "More collected by …".
    private enum PersonRowPresets {
        case sender
        case recipient
        case collectorOnly

        /// Whether the current card already matches the given preset kind for a row of this
        /// type — i.e. whether that preset's button should read "More …" rather than a bare
        /// call to action.
        func alreadyMatches(_ kind: SearchToken.Kind) -> Bool {
            switch (self, kind) {
            case (.sender, .from), (.sender, .with): true
            case (.recipient, .to), (.recipient, .with): true
            case (.collectorOnly, .collector): true
            default: false
            }
        }
    }

    @ViewBuilder
    private func personRow(_ person: Person, label: String, presets: PersonRowPresets) -> some View {
        if let name = person.name, !name.isEmpty {
            LabeledContent(label) {
                Menu {
                    switch presets {
                    case .sender, .recipient:
                        presetButton(kind: .from, verb: "from", presets: presets, name: name, person: person)
                        presetButton(kind: .to, verb: "to", presets: presets, name: name, person: person)
                        presetButton(kind: .with, verb: "with", presets: presets, name: name, person: person)
                    case .collectorOnly:
                        presetButton(kind: .collector, verb: "collected by", presets: presets, name: name, person: person)
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

    /// A preset button's title and its submitted token are independent: the wording reflects
    /// whether the CURRENT card already matches this preset for this row (see
    /// `PersonRowPresets.alreadyMatches`), while the token itself (kind + display + value) is
    /// always the same regardless of wording, so the grid picks up an identical search either
    /// way.
    private func presetButton(
        kind: SearchToken.Kind, verb: String, presets: PersonRowPresets, name: String, person: Person
    ) -> some View {
        let title = presets.alreadyMatches(kind)
            ? "More \(verb) \(name)"
            : "\(verb.prefix(1).uppercased())\(verb.dropFirst()) \(name)"
        return Button(title) {
            onSearchPreset(SearchToken(kind: kind, display: person.name ?? "", value: presetValue(for: person)))
        }
    }

    /// A preset token's underlying search value: the person's URI when they have one that
    /// parses, else their name — reused by every `presetButton` so "more from"/"more
    /// to"/"more with"/"more collected by" all search the same identifier a promoted or
    /// suggested pill for this same person would.
    private func presetValue(for person: Person) -> String {
        validURL(for: person) != nil ? (person.uri ?? "") : (person.name ?? "")
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
            Link(VisitLabel.text(for: url), destination: url)
        }
    }

    /// A block of text with a small "front"/"back" caption pinned to its bottom-right corner.
    /// Used wherever a card's two sides supply the same kind of content (transcription, alt
    /// text) side by side — `caption` is `nil` when only one side has that content, so a lone
    /// block reads as plain text with no "which side is this" label needed.
    @ViewBuilder
    private func captionedBlock(caption: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
