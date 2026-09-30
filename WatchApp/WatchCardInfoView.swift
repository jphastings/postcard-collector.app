import CoreLocation
import MapKit
import SwiftUI

/// A postcard's info page on the watch, opened by long-pressing the card: the short facts
/// first — when it was sent, who from and to, and where from (with a small map when the card
/// has coordinates) — then the longer texts: its transcribed message, notes, and
/// descriptions. It's one scrolling list the Digital Crown runs through, each row a label
/// stacked over its value so nothing is truncated to fit beside a label on the narrow
/// screen. What it shows mirrors `CardInfoPanel` on iPhone and Mac.
///
/// The details travel separately from the images (`WatchRelay.opDetails`), so a collection
/// whose details haven't landed yet says so — and asks for them, in case its cache predates
/// them.
struct WatchCardInfoView: View {
    let library: WatchLibrary
    let collectionID: String
    let meta: WatchCardMeta

    private var details: WatchCardDetails? {
        library.details(for: collectionID, cardName: meta.name)
    }

    var body: some View {
        NavigationStack {
            List {
                if let details {
                    sections(for: details)
                } else {
                    Text(library.isPhoneReachable
                         ? "This postcard's details are on their way from your iPhone."
                         : "This postcard's details will arrive from your iPhone next time it's nearby.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(meta.name)
        }
        .task {
            if details == nil {
                library.requestDownloadIfNeeded(id: collectionID)
            }
        }
    }

    @ViewBuilder
    private func sections(for details: WatchCardDetails) -> some View {
        if details.sentOn != nil || details.senderName != nil || details.recipientName != nil {
            Section {
                if let sentOn = details.sentOn {
                    InfoRow(label: "Sent", systemImage: "calendar", value: sentOn.date.formatted(date: .long, time: .omitted))
                }
                if let sender = details.senderName {
                    InfoRow(label: "From", systemImage: "person", value: sender)
                }
                if let recipient = details.recipientName {
                    InfoRow(label: "To", systemImage: "person.fill", value: recipient)
                }
            }
        }

        let location = details.location
        if LocationDisplay.showsSection(for: location) {
            Section {
                InfoRow(label: "Sent from", systemImage: "mappin.and.ellipse", value: placeName(location))
                if let latitude = location.latitude, let longitude = location.longitude {
                    LocationMap(
                        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                        name: location.name ?? meta.name
                    )
                }
            }
        }

        if details.frontTranscription != nil || details.backTranscription != nil {
            Section("Message") {
                captionedText(details.frontTranscription, caption: details.backTranscription == nil ? nil : "Front")
                captionedText(details.backTranscription, caption: details.frontTranscription == nil ? nil : "Back")
            }
        }

        if details.notes != nil || details.collectorName != nil {
            Section("Context") {
                if let notes = details.notes {
                    Text(notes)
                }
                if let collector = details.collectorName {
                    InfoRow(label: "Catalogued by", systemImage: "person.crop.square", value: collector)
                }
            }
        }

        if details.frontDescription != nil || details.backDescription != nil {
            Section("Description") {
                captionedText(details.frontDescription, caption: details.backDescription == nil ? nil : "Front")
                captionedText(details.backDescription, caption: details.frontDescription == nil ? nil : "Back")
            }
        }
    }

    /// The place's name with its country's flag, as `CardInfoPanel` shows it.
    private func placeName(_ location: Location) -> String {
        let name = location.name ?? "Unknown"
        guard let flag = location.countryCode.flatMap(CountryFlags.flag(forAlpha3:)) else { return name }
        return "\(flag) \(name)"
    }

    /// One side's text, captioned with which side it's from only when both sides have some.
    @ViewBuilder
    private func captionedText(_ text: String?, caption: String?) -> some View {
        if let text {
            VStack(alignment: .leading, spacing: 2) {
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.footnote)
            }
        }
    }
}

/// A label with its icon, stacked over its value.
private struct InfoRow: View {
    let label: String
    let systemImage: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A small, still map with a pin on the place the card was sent from. It doesn't take
/// touches or the Digital Crown, which scroll the page around it instead.
private struct LocationMap: View {
    let coordinate: CLLocationCoordinate2D
    let name: String

    var body: some View {
        Map(
            initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)),
            interactionModes: []
        ) {
            Marker(name, coordinate: coordinate)
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
