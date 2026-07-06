import CoreLocation
import MapKit
import SwiftUI

/// The metadata side panel for a card: sheet on iOS, inspector on macOS (see
/// `CardDetailView`). Shows descriptions, sender/recipient, sent date, a map when
/// coordinates are present, the location's flag, transcriptions, and cataloguing context.
struct CardInfoPanel: View {
    let summary: CardSummary
    let metadata: PostcardMetadata

    var body: some View {
        Form {
            if let sentOn = metadata.sentOn ?? summary.sentOn {
                LabeledContent("Sent") {
                    Text(sentOn.date.formatted(date: .long, time: .omitted))
                }
            }

            Section("From & to") {
                personRow(metadata.sender, label: "Sender")
                personRow(metadata.recipient, label: "Recipient")
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
                        Map(initialPosition: .region(
                            MKCoordinateRegion(center: coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
                        )) {
                            Marker(location.name ?? summary.name, coordinate: coordinate)
                        }
                        .frame(height: 180)
                        .allowsHitTesting(false)
                        .listRowInsets(EdgeInsets())
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
                    personRow(metadata.context.author, label: "Catalogued by")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(summary.name)
    }

    private var displayableLocation: Location? {
        let location = metadata.location
        return LocationDisplay.showsSection(for: location) ? location : nil
    }

    private var hasContext: Bool {
        !(metadata.context.description ?? "").isEmpty || !(metadata.context.author.name ?? "").isEmpty
    }

    @ViewBuilder
    private func personRow(_ person: Person, label: String) -> some View {
        if let name = person.name, !name.isEmpty {
            LabeledContent(label) {
                if let uri = person.uri, let url = URL(string: uri) {
                    Link(name, destination: url)
                } else {
                    Text(name)
                }
            }
        }
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
