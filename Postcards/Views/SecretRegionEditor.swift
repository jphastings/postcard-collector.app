import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Sheet editor for one side's secret regions: drag to draw a rectangle, drag a handle to
/// resize, drag inside a region to move it, right-click/long-press to delete. Every region
/// renders identically — the compile pipeline simply erases all of them, so there's no
/// "already hidden" distinction for the UI to show (`SecretRegion.prehidden` still exists in
/// Core for the file format, but this editor never sets or reads it). `regions` binds live —
/// there's no separate save, `Done` just dismisses.
///
/// Gesture disambiguation (see `regionEditGesture`/`beginInteraction`): a press is a RESIZE
/// if it lands on the selected region's handle, a MOVE if it lands inside any region (which
/// also selects that region), otherwise it's the start of a new region (deselecting whatever
/// was selected). All three share one `DragGesture(minimumDistance: 0)` attached with
/// `.highPriorityGesture` to the outer, untransformed canvas — the same "gestures on an
/// untransformed container" rule `CardDetailView` documents, since the image content itself
/// carries the pinch-zoom `.scaleEffect`/`.offset`. Zoom/pan is a separate, simplified
/// `SimultaneousGesture`: pinch scales around the canvas center (no anchor-preserving math —
/// combining that with a live two-finger pan is a lot of geometry for a feature the plan
/// calls secondary to correctness) and a two-finger drag pans, gated on `isPinching` so a
/// single-finger drag never fights the region-editing gesture for the same touch.
///
/// All rect/point math is `SecretRegion`/`LoupeGeometry` statics (Core, unit-tested); this
/// view only wires gestures to them and draws the result.
struct SecretRegionEditor: View {
    let imageData: Data
    @Binding var regions: [SecretRegion]

    @Environment(\.dismiss) private var dismiss

    @State private var decodedImage: CGImage?
    @State private var decodeFailed = false

    @State private var selectedID: SecretRegion.ID?
    @State private var interaction: Interaction?
    @State private var creatingRect: CGRect?
    @State private var activeDisplayPoint: CGPoint?

    @State private var zoomScale: CGFloat = 1
    @State private var lastZoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var lastZoomOffset: CGSize = .zero
    @State private var isPinching = false

    private let minZoomScale: CGFloat = 1
    private let maxZoomScale: CGFloat = 6
    private static let handleTouchTolerance: CGFloat = 22
    private static let minimumCreateDragDistance: CGFloat = 4
    private static let loupeDiameter: CGFloat = 130
    private static let loupeMagnification: CGFloat = 3
    /// All drawn regions render identically — every one is simply erased at compile time,
    /// so there's no "already hidden" distinction left for the UI to show.
    private static let regionColor: Color = .orange

    private enum Interaction {
        case creating(start: CGPoint)
        case resizing(id: SecretRegion.ID, handle: SecretRegion.Handle, originalRect: CGRect)
        case moving(id: SecretRegion.ID, originalRect: CGRect)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let decodedImage {
                    editorCanvas(decodedImage: decodedImage)
                } else if decodeFailed {
                    ContentUnavailableView("Couldn't Load Image", systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("Loading…")
                }
            }
            .navigationTitle("Mark Secrets")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if zoomScale > minZoomScale {
                        Button("Reset Zoom", systemImage: "arrow.down.right.and.arrow.up.left") { resetZoom() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .background(deleteKeyCatcher)
        }
        .task(id: imageData) { await decode() }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 440)
        #endif
    }

    // MARK: - Canvas

    @ViewBuilder
    private func editorCanvas(decodedImage: CGImage) -> some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let imagePixelSize = CGSize(width: CGFloat(decodedImage.width), height: CGFloat(decodedImage.height))
            let displayFrame = SecretRegion.fittedFrame(ofContentSize: imagePixelSize, in: containerSize)

            ZStack(alignment: .topLeading) {
                canvasContent(decodedImage: decodedImage, displayFrame: displayFrame)
                    .frame(width: containerSize.width, height: containerSize.height)
                    .scaleEffect(zoomScale)
                    .offset(zoomOffset)

                if let activeDisplayPoint {
                    loupe(
                        decodedImage: decodedImage,
                        imagePixelSize: imagePixelSize,
                        displayFrame: displayFrame,
                        containerSize: containerSize,
                        activePoint: activeDisplayPoint
                    )
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .contentShape(Rectangle())
            .clipped()
            .gesture(SimultaneousGesture(magnifyGesture, panGesture))
            .highPriorityGesture(regionEditGesture(containerSize: containerSize, displayFrame: displayFrame))
        }
        .safeAreaInset(edge: .top) { instructions }
    }

    /// Image + region overlays, all positioned in one shared "unscaled content" space
    /// (container-sized, image letterboxed within it at `displayFrame`) — the whole thing
    /// gets `.scaleEffect`/`.offset` applied together by the caller, so alignment between the
    /// image and its region outlines is automatic at any zoom/pan.
    private func canvasContent(decodedImage: CGImage, displayFrame: CGRect) -> some View {
        ZStack {
            Image(decorative: decodedImage, scale: 1)
                .resizable()
                .frame(width: displayFrame.width, height: displayFrame.height)
                .position(x: displayFrame.midX, y: displayFrame.midY)

            ForEach(regions) { region in
                regionOverlay(region, displayFrame: displayFrame)
            }

            if let creatingRect {
                MarchingAntsRegion(color: Self.regionColor)
                    .frame(width: creatingRect.width, height: creatingRect.height)
                    .position(x: displayFrame.minX + creatingRect.midX, y: displayFrame.minY + creatingRect.midY)
            }
        }
    }

    private func regionOverlay(_ region: SecretRegion, displayFrame: CGRect) -> some View {
        let rect = SecretRegion.viewRect(ofNormalized: region.rect, displaySize: displayFrame.size)
        return Group {
            if region.id == selectedID {
                SelectedRegionView(color: Self.regionColor, size: rect.size)
            } else {
                UnselectedRegionView(color: Self.regionColor)
            }
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .position(x: displayFrame.minX + rect.midX, y: displayFrame.minY + rect.midY)
        .contextMenu {
            Button("Delete", role: .destructive) { delete(region.id) }
        }
    }

    /// The loupe floats OUTSIDE the zoomed/panned canvas content (a sibling in `editorCanvas`'s
    /// ZStack, not inside the `.scaleEffect`d one) so it always renders at a constant, crisp
    /// size regardless of the current pinch zoom.
    private func loupe(
        decodedImage: CGImage,
        imagePixelSize: CGSize,
        displayFrame: CGRect,
        containerSize: CGSize,
        activePoint: CGPoint
    ) -> some View {
        let normalizedCenter = SecretRegion.normalizedPoint(ofView: activePoint, displaySize: displayFrame.size)
        let pixelMagnification = LoupeGeometry.effectiveMagnification(
            Self.loupeMagnification, zoomScale: zoomScale, imagePixelSize: imagePixelSize, displaySize: displayFrame.size
        )
        let onScreenPoint = SecretRegion.containerPoint(
            ofDisplayPoint: activePoint,
            containerSize: containerSize,
            displayFrame: displayFrame,
            zoomScale: zoomScale,
            zoomOffset: zoomOffset
        )
        let position = LoupeGeometry.position(for: onScreenPoint, containerSize: containerSize, diameter: Self.loupeDiameter)
        let active = activeRegion(displaySize: displayFrame.size)

        return Loupe(
            image: decodedImage,
            normalizedCenter: normalizedCenter,
            pixelMagnification: pixelMagnification,
            diameter: Self.loupeDiameter,
            activeRegionRect: active?.rect,
            activeHandle: active?.handle,
            color: Self.regionColor
        )
        .position(position)
        .allowsHitTesting(false)
    }

    /// The region rect (normalized, image space) and — for a resize — the handle being
    /// dragged, so the loupe can render the region's own boundary under magnification
    /// alongside the crosshair marking the raw touch point. `nil` when nothing is being
    /// dragged (the loupe itself is only shown while `activeDisplayPoint` is set, so in
    /// practice this only returns `nil` for the one frame before `interaction` catches up).
    private func activeRegion(displaySize: CGSize) -> (rect: CGRect, handle: SecretRegion.Handle?)? {
        guard let interaction else { return nil }
        switch interaction {
        case .creating:
            guard let creatingRect else { return nil }
            return (SecretRegion.normalizedRect(ofView: creatingRect, displaySize: displaySize), nil)
        case .resizing(let id, let handle, _):
            guard let region = regions.first(where: { $0.id == id }) else { return nil }
            return (region.rect, handle)
        case .moving(let id, _):
            guard let region = regions.first(where: { $0.id == id }) else { return nil }
            return (region.rect, nil)
        }
    }

    // MARK: - Region create/resize/move gesture

    private func regionEditGesture(containerSize: CGSize, displayFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = SecretRegion.displayPoint(
                    ofContainerPoint: value.location,
                    containerSize: containerSize,
                    displayFrame: displayFrame,
                    zoomScale: zoomScale,
                    zoomOffset: zoomOffset
                )
                activeDisplayPoint = point

                guard let current = interaction else {
                    let started = beginInteraction(at: point, displaySize: displayFrame.size)
                    interaction = started
                    if case .creating = started {
                        creatingRect = CGRect(origin: point, size: .zero)
                    }
                    return
                }

                switch current {
                case .creating(let start):
                    creatingRect = SecretRegion.rubberBand(from: start, to: point)
                case .resizing(let id, let handle, let originalRect):
                    guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
                    let delta = normalizedDelta(from: value.translation, displaySize: displayFrame.size)
                    regions[index].rect = SecretRegion.applying(delta: delta, to: handle, of: originalRect)
                case .moving(let id, let originalRect):
                    guard let index = regions.firstIndex(where: { $0.id == id }) else { return }
                    let delta = normalizedDelta(from: value.translation, displaySize: displayFrame.size)
                    regions[index].rect = SecretRegion.moved(originalRect, by: delta)
                }
            }
            .onEnded { value in
                defer {
                    interaction = nil
                    creatingRect = nil
                    activeDisplayPoint = nil
                }
                guard case .creating = interaction, let creatingRect else { return }
                // A stray tap (no real drag) on empty canvas just deselects rather than
                // leaving behind a stray minimum-size region.
                guard hypot(value.translation.width, value.translation.height) > Self.minimumCreateDragDistance else { return }
                let region = SecretRegion(rect: SecretRegion.normalizedRect(ofView: creatingRect, displaySize: displayFrame.size))
                regions.append(region)
                selectedID = region.id
            }
    }

    /// Handles are only hit-tested on the SELECTED region (unselected regions render no
    /// handles at all — see `regionOverlay`); a press inside any region falls through to a
    /// move, selecting it first if it wasn't already; otherwise a new region begins.
    private func beginInteraction(at point: CGPoint, displaySize: CGSize) -> Interaction {
        let tolerance = Self.handleTouchTolerance / max(zoomScale, 0.0001)
        if let selectedID, let selected = regions.first(where: { $0.id == selectedID }),
           let handle = selected.handle(at: point, displaySize: displaySize, tolerance: tolerance) {
            return .resizing(id: selectedID, handle: handle, originalRect: selected.rect)
        }
        if let hit = regions.reversed().first(where: { SecretRegion.viewRect(ofNormalized: $0.rect, displaySize: displaySize).contains(point) }) {
            self.selectedID = hit.id
            return .moving(id: hit.id, originalRect: hit.rect)
        }
        self.selectedID = nil
        return .creating(start: point)
    }

    /// Container-space drag translation, undoing the current pinch zoom then normalizing —
    /// the delta space `SecretRegion.applying(delta:to:of:)`/`moved(_:by:)` expect. Deltas
    /// (unlike absolute points) don't need the letterbox origin subtracted.
    private func normalizedDelta(from translation: CGSize, displaySize: CGSize) -> CGVector {
        CGVector(dx: translation.width / zoomScale / displaySize.width, dy: translation.height / zoomScale / displaySize.height)
    }

    // MARK: - Zoom & pan

    // Center-anchored (not anchored at the pinch point, unlike `CardDetailView`'s
    // `ZoomGeometry`-based zoom) — keeping an anchor fixed while ALSO live-panning from a
    // second finger needs the two to share one offset formula, which is a lot of geometry
    // for a feature the plan explicitly calls secondary to correctness. Simple and robust
    // instead: `panGesture` is gated on `isPinching`, so it only ever applies during an
    // active two-finger pinch (a lone finger is entirely the region-editing gesture's).
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                isPinching = true
                zoomScale = min(max(lastZoomScale * value.magnification, minZoomScale), maxZoomScale)
            }
            .onEnded { _ in
                isPinching = false
                lastZoomScale = zoomScale
                if zoomScale <= minZoomScale { resetZoom() }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isPinching else { return }
                zoomOffset = CGSize(width: lastZoomOffset.width + value.translation.width, height: lastZoomOffset.height + value.translation.height)
            }
            .onEnded { _ in
                guard isPinching else { return }
                lastZoomOffset = zoomOffset
            }
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoomScale = 1
            lastZoomScale = 1
            zoomOffset = .zero
            lastZoomOffset = .zero
        }
    }

    // MARK: - Per-region controls

    private func delete(_ id: SecretRegion.ID) {
        regions.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    private func deleteSelectedRegion() {
        guard let selectedID else { return }
        delete(selectedID)
    }

    /// A zero-size button rather than `.onDeleteCommand` — more reliable in practice for
    /// routing Delete/Backspace to a single selection that isn't hosted in a `List`.
    private var deleteKeyCatcher: some View {
        Button("Delete Selected Region", action: deleteSelectedRegion)
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(selectedID == nil)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: - Instructions

    private var instructions: some View {
        Text("Drag to cover anything that shouldn't be shared — it will be erased from the saved postcard.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }

    // MARK: - Decoding

    /// Decodes once, off-main, at full resolution with EXIF orientation applied (matching
    /// `ImageDropWell`'s own thumbnail preview) — every subsequent frame (region drags, the
    /// loupe) reuses this same `CGImage` via cheap `cropping(to:)` calls, never redecoding.
    private func decode() async {
        decodeFailed = false
        let image = await Task.detached(priority: .userInitiated) {
            Self.decodeFullImage(from: imageData)
        }.value
        if let image {
            decodedImage = image
        } else {
            decodeFailed = true
        }
    }

    private nonisolated static func decodeFullImage(from data: Data) -> CGImage? {
        guard
            let probed = ProbedImage.probe(data: data),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else {
            return nil
        }
        // `CGImageSourceCreateImageAtIndex` doesn't apply EXIF orientation; the thumbnail
        // path does (`kCGImageSourceCreateThumbnailWithTransform`), so it's used here too,
        // bounded at the image's own max dimension so nothing is actually downsampled.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(probed.pixelWidth, probed.pixelHeight),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - Region rendering

private struct MarchingAnts: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * -12
            Rectangle().stroke(color, style: StrokeStyle(lineWidth: 2, dash: [6, 4], dashPhase: phase))
        }
    }
}

private struct MarchingAntsRegion: View {
    let color: Color
    var body: some View {
        ZStack {
            Rectangle().fill(color.opacity(0.18))
            MarchingAnts(color: color)
        }
    }
}

private struct SelectedRegionView: View {
    let color: Color
    let size: CGSize

    var body: some View {
        MarchingAntsRegion(color: color)
            .overlay {
                ForEach(SecretRegion.Handle.allCases, id: \.self) { handle in
                    HandleDot(color: color)
                        .position(x: handle.fraction.x * size.width, y: handle.fraction.y * size.height)
                }
            }
    }
}

private struct HandleDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
            .frame(width: 12, height: 12)
            .shadow(radius: 1)
    }
}

private struct UnselectedRegionView: View {
    let color: Color
    var body: some View {
        ZStack {
            Rectangle().fill(color.opacity(0.1))
            Rectangle().stroke(color, lineWidth: 1.25)
        }
    }
}

// MARK: - Loupe

/// Draws a zoomed, cropped circle of `image` centered on `normalizedCenter` with a crosshair
/// at the raw touch point, plus — while `activeRegionRect` is set — the portion of that
/// region's own boundary that falls within the magnified crop, so the precision of an
/// edge/corner placement is visible under magnification, not just the touch location (which,
/// for a resize started slightly off the handle, isn't the same point as the edge it's
/// moving). Reads pixels via `CGImage.cropping(to:)` on the ALREADY-decoded image (no
/// redecode), so this is cheap enough to redraw every drag frame without flicker or lag.
private struct Loupe: View {
    let image: CGImage
    let normalizedCenter: CGPoint
    let pixelMagnification: CGFloat
    let diameter: CGFloat
    /// The active region's rect, normalized image space — `nil` when nothing is being dragged.
    let activeRegionRect: CGRect?
    /// The handle being dragged, for a resize — `nil` for a move/create, or a resize whose
    /// handle only owns one edge (in which case only that edge, not two, draws heavier).
    let activeHandle: SecretRegion.Handle?
    let color: Color

    private static let regionStrokeWidth: CGFloat = 1.5
    private static let activeEdgeStrokeWidth: CGFloat = 3.5

    var body: some View {
        let imagePixelSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let sourceRect = LoupeGeometry.sourceRect(
            normalizedCenter: normalizedCenter,
            imagePixelSize: imagePixelSize,
            loupeDiameter: diameter,
            pixelMagnification: pixelMagnification
        )
        let cropped = image.cropping(to: sourceRect)
        let magnifiedRegionRect = activeRegionRect.map {
            LoupeGeometry.magnifiedRect(ofNormalized: $0, imagePixelSize: imagePixelSize, sourceRect: sourceRect, pixelMagnification: pixelMagnification)
        }

        Canvas { context, size in
            let circle = Path(ellipseIn: CGRect(origin: .zero, size: size))
            context.clip(to: circle)
            context.fill(circle, with: .color(.black))
            if let cropped {
                context.draw(Image(decorative: cropped, scale: 1), in: CGRect(origin: .zero, size: size))
            }

            if let magnifiedRegionRect {
                context.stroke(Path(magnifiedRegionRect), with: .color(color), lineWidth: Self.regionStrokeWidth)
                if let activeHandle {
                    context.stroke(
                        activeEdgesPath(of: magnifiedRegionRect, handle: activeHandle),
                        with: .color(color),
                        lineWidth: Self.activeEdgeStrokeWidth
                    )
                }
            }

            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            var crosshair = Path()
            crosshair.move(to: CGPoint(x: mid.x - 9, y: mid.y))
            crosshair.addLine(to: CGPoint(x: mid.x + 9, y: mid.y))
            crosshair.move(to: CGPoint(x: mid.x, y: mid.y - 9))
            crosshair.addLine(to: CGPoint(x: mid.x, y: mid.y + 9))
            context.stroke(crosshair, with: .color(.white), lineWidth: 1.5)
            context.stroke(crosshair, with: .color(.black.opacity(0.5)), lineWidth: 0.5)

            context.stroke(circle, with: .color(.white), lineWidth: 2)
        }
        .frame(width: diameter, height: diameter)
        .shadow(radius: 8)
    }

    /// Just the edge(s) `handle` owns (`SecretRegion.Handle.movesMinX` etc — reused here so
    /// this can't disagree with which edges the drag itself actually moves): a corner handle
    /// traces the two edges meeting there, a midpoint handle traces its one edge, so restroking
    /// them heavier on top of the base outline reads as "this is what you're moving."
    private func activeEdgesPath(of rect: CGRect, handle: SecretRegion.Handle) -> Path {
        var path = Path()
        if handle.movesMinY {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        if handle.movesMaxY {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        if handle.movesMinX {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        if handle.movesMaxX {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        return path
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Secret Region Editor") {
    SecretRegionEditor(
        imageData: previewPlaceholderImageData(),
        regions: .constant([
            SecretRegion(rect: CGRect(x: 0.58, y: 0.68, width: 0.3, height: 0.18)),
            SecretRegion(rect: CGRect(x: 0.08, y: 0.08, width: 0.18, height: 0.12)),
        ])
    )
}

/// A generated postcard-ish placeholder (border, "stamp" corner, ruled "message" lines) so
/// the preview above needs no bundled fixture image to iterate on this view.
private func previewPlaceholderImageData(width: Int = 900, height: Int = 600) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return Data() }

    let w = CGFloat(width)
    let h = CGFloat(height)

    context.setFillColor(CGColor(red: 0.93, green: 0.90, blue: 0.83, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))

    context.setStrokeColor(CGColor(red: 0.55, green: 0.42, blue: 0.3, alpha: 1))
    context.setLineWidth(6)
    context.stroke(CGRect(x: 20, y: 20, width: w - 40, height: h - 40))

    context.setFillColor(CGColor(red: 0.75, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: w - 160, y: 40, width: 100, height: 130))

    context.setStrokeColor(CGColor(gray: 0.3, alpha: 1))
    context.setLineWidth(1)
    for y in stride(from: CGFloat(200), to: h - 60, by: 40) {
        context.stroke(CGRect(x: 60, y: y, width: w / 2, height: 1))
    }

    guard let cgImage = context.makeImage() else { return Data() }
    let mutableData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil) else { return Data() }
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
    return mutableData as Data
}
#endif
