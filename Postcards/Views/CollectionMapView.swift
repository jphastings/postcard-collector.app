import CoreLocation
import MapKit
import SwiftUI

/// One card placeable on `CollectionMapView`, paired with the `CardReference` that opens it
/// in `CardDetailView` — `CollectionGridView` builds these as `.inCollection`,
/// `SinglePostcardsGridView` as `.bareFile`, which is the only thing that differs between
/// the two call sites (see `GoCore.image(for:)`/`metadata(for:)`, which already abstract
/// over both kinds of reference).
struct MapCardEntry: Identifiable {
    var summary: CardSummary
    var reference: CardReference

    var id: String { reference.id }
}

/// The collection view's "map mode" (see `CollectionModeSwitcher`): a pin for every entry
/// with a coordinate, framed so all of them are visible on first appearance. Tapping a pin
/// raises a small flippable preview of that card anchored above it (`MapPinAnnotation`);
/// tapping the map elsewhere, or another pin, closes/switches it — only one is ever open.
struct CollectionMapView: View {
    let entries: [MapCardEntry]
    @Binding var selection: CardReference?

    @State private var cameraPosition: MapCameraPosition
    @State private var selectedEntryID: String?

    init(entries: [MapCardEntry], selection: Binding<CardReference?>) {
        self.entries = entries
        self._selection = selection
        let coordinates = entries.compactMap(\.summary.coordinate)
        if let region = MapRegionFitting.region(for: coordinates) {
            _cameraPosition = State(initialValue: .region(region))
        } else {
            _cameraPosition = State(initialValue: .automatic)
        }
    }

    private var pinnedEntries: [(entry: MapCardEntry, coordinate: CLLocationCoordinate2D)] {
        entries.compactMap { entry in
            guard let coordinate = entry.summary.coordinate else { return nil }
            return (entry, coordinate)
        }
    }

    var body: some View {
        Map(position: $cameraPosition) {
            ForEach(pinnedEntries, id: \.entry.id) { pinned in
                // Qualified: `Models.swift` already declares its own `Annotation` (for
                // postcard transcriptions), which shadows MapKit's SwiftUI `Annotation`
                // content type in this module.
                MapKit.Annotation(pinned.entry.summary.name, coordinate: pinned.coordinate, anchor: .bottom) {
                    MapPinAnnotation(
                        entry: pinned.entry,
                        isSelected: selectedEntryID == pinned.entry.id,
                        onToggle: { toggle(pinned.entry) },
                        onExpand: { selection = pinned.entry.reference }
                    )
                }
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        // Lets tapping empty water/land close whatever pin is open — Map's own gesture
        // handling for panning/zooming is a drag/magnify, not a tap, so this doesn't
        // interfere with it, and the pin buttons underneath consume their own taps first.
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { selectedEntryID = nil }
        }
    }

    private func toggle(_ entry: MapCardEntry) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedEntryID = (selectedEntryID == entry.id) ? nil : entry.id
        }
    }
}

/// One pin's content: always a marker glyph, plus — when selected — a small flippable card
/// (reusing `FlippableCardView` exactly as `CardDetailView` does, just sized down) with an
/// expand button that hands off to the same `selection` binding the grid uses.
private struct MapPinAnnotation: View {
    let entry: MapCardEntry
    let isSelected: Bool
    let onToggle: () -> Void
    let onExpand: () -> Void

    @State private var splitImage: SplitPostcardImage?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 6) {
            if isSelected {
                miniCard
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            Button(action: onToggle) {
                Image(systemName: "mappin.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .background(Circle().fill(.white).padding(3))
            }
            .buttonStyle(.plain)
            // Stable machine-facing handle for UI tests, same convention as GridCell.
            .accessibilityIdentifier(entry.summary.name)
            .accessibilityLabel(entry.summary.name)
        }
        .task(id: "\(entry.id)#\(isSelected)") {
            if isSelected { await loadIfNeeded() }
        }
    }

    private var frontPixelSize: CGSize {
        CGSize(width: CGFloat(entry.summary.frontPxW), height: CGFloat(entry.summary.frontPxH))
    }

    @ViewBuilder
    private var miniCard: some View {
        let frameSize = MiniCardSizing.frameSize(forFrontSize: frontPixelSize, flip: entry.summary.flip)

        ZStack(alignment: .topTrailing) {
            Group {
                if let splitImage {
                    FlippableCardView(
                        front: splitImage.front,
                        back: splitImage.back,
                        flip: entry.summary.flip,
                        frontPixelSize: frontPixelSize
                    )
                } else if let loadError {
                    ContentUnavailableView(
                        "Couldn't load",
                        systemImage: "exclamationmark.triangle",
                        description: Text(loadError)
                    )
                } else {
                    ProgressView()
                }
            }
            .frame(width: frameSize.width, height: frameSize.height)

            Button(action: onExpand) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .padding(6)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(entry.summary.name)")
            .offset(x: 8, y: -8)
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 8, y: 4)
    }

    private func loadIfNeeded() async {
        guard splitImage == nil, loadError == nil else { return }
        do {
            let data = try await GoCore.shared.image(for: entry.reference)
            let flip = entry.summary.flip
            splitImage = try await Task.detached(priority: .userInitiated) {
                try ImageSplitter.split(data: data, flip: flip)
            }.value
        } catch {
            loadError = error.localizedDescription
        }
    }
}
