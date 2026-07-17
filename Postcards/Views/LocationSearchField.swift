import MapKit
import SwiftUI

/// Search-as-you-type location autofill for the top of "Create a Postcard"'s Location
/// section: an `MKLocalSearchCompleter`-backed suggestions list that, on selection, resolves
/// the full placemark via `MKLocalSearch` and overwrites the four bound fields. Purely an
/// autofill — the fields it writes stay freely editable afterward — and knows nothing about
/// `CreatePostcardModel`; these four bindings are its entire contract with the caller.
///
/// Needs no location permission: it never touches `CLLocationManager` or the device's actual
/// location, so no `NSLocationWhenInUseUsageDescription` or entitlement applies (see
/// `LocationSearchCompleterModel`, which never assigns `MKLocalSearchCompleter.region`).
struct LocationSearchField: View {
    @Binding var name: String
    @Binding var latitude: Double?
    @Binding var longitude: Double?
    @Binding var countryCode: String
    /// Bumped whenever `apply(_:fallbackTitle:)` overwrites the coordinate — see
    /// `LocationPickerMap.recenterTrigger`'s doc comment for why this can't just be
    /// `latitude`/`longitude` changing.
    @Binding var recenterTrigger: Int

    @State private var completer = LocationSearchCompleterModel()
    @State private var queryText = ""
    @State private var highlightedIndex = 0
    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Search for a place…", text: $queryText)
                    .onChange(of: queryText) { _, newValue in
                        highlightedIndex = 0
                        completer.search(for: newValue)
                    }
                    .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                    .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                    .onKeyPress(.return) { selectHighlighted() }
                if isResolving {
                    ProgressView().controlSize(.small)
                }
            }
            if !completer.results.isEmpty {
                suggestionsList
            }
        }
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completer.results.enumerated()), id: \.offset) { index, completion in
                Button {
                    select(completion)
                } label: {
                    suggestionRow(completion, isHighlighted: index == highlightedIndex)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private func suggestionRow(_ completion: MKLocalSearchCompletion, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(completion.title)
            if !completion.subtitle.isEmpty {
                Text(completion.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .contentShape(Rectangle())
    }

    private func moveHighlight(by delta: Int) -> KeyPress.Result {
        guard !completer.results.isEmpty else { return .ignored }
        highlightedIndex = max(0, min(completer.results.count - 1, highlightedIndex + delta))
        return .handled
    }

    private func selectHighlighted() -> KeyPress.Result {
        guard completer.results.indices.contains(highlightedIndex) else { return .ignored }
        select(completer.results[highlightedIndex])
        return .handled
    }

    private func select(_ completion: MKLocalSearchCompletion) {
        queryText = completion.title
        completer.clearResults()
        isResolving = true
        Task {
            defer { isResolving = false }
            guard let mapItem = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first else {
                return
            }
            apply(mapItem, fallbackTitle: completion.title)
        }
    }

    /// Overwrites all four fields at once — selecting a suggestion is meant to replace
    /// whatever was there, not merge with it.
    private func apply(_ mapItem: MKMapItem, fallbackTitle: String) {
        let placemark = mapItem.placemark
        name = LocationSearchNaming.displayName(
            locality: placemark.locality,
            administrativeArea: placemark.administrativeArea,
            country: placemark.country,
            fallbackTitle: fallbackTitle
        )
        latitude = placemark.coordinate.latitude
        longitude = placemark.coordinate.longitude
        countryCode = placemark.isoCountryCode.flatMap(CountryFlags.alpha3(forAlpha2:)) ?? ""
        recenterTrigger += 1
    }
}

/// Owns the `MKLocalSearchCompleter` delegate lifecycle. `@Observable` so `results` drives
/// `LocationSearchField` directly; `@MainActor` because the completer's delegate callbacks
/// touch it, and only `NSObject`/`MKLocalSearchCompleterDelegate` conformance requires the
/// two callbacks themselves to be `nonisolated`.
@MainActor
@Observable
final class LocationSearchCompleterModel: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()
    private var debounceTask: Task<Void, Never>?

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    /// Debounces ~250ms before handing the fragment to the completer, on top of whatever
    /// internal throttling it already does — cheap insurance against dispatching a
    /// network-backed lookup on every keystroke of a fast typist.
    func search(for fragment: String) {
        debounceTask?.cancel()
        guard !fragment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completer.queryFragment = ""
            results = []
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.completer.queryFragment = fragment
        }
    }

    func clearResults() {
        debounceTask?.cancel()
        completer.queryFragment = ""
        results = []
    }

    /// The completer's success delegate callback — re-reads `completer.results` from `self`
    /// rather than the (non-`Sendable`) parameter, since it's the same instance as `self`'s
    /// own `completer`.
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.results = self.completer.results
        }
    }

    /// The completer's failure delegate callback, handled quietly: suggestions just
    /// disappear, and the manual fields below always remain — there's nothing more useful to
    /// surface for a suggestions list.
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.results = []
        }
    }
}
