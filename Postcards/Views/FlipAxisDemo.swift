import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// A square, never-pausing demo of a postcard's flip: the actual front/back scans rotate
/// continuously through one full revolution every `revolutionPeriod` seconds, so a glance at
/// this square shows exactly what the chosen flip axis will look like — no tap needed. Reuses
/// `FlipFace`/`FlipGeometry` (the same 3D rotation + hard-cut backface visibility
/// `FlippableCardView` uses for its tap-to-flip), just driven by a `TimelineView(.animation)`
/// tick instead of a toggled angle, since this never settles at rest.
struct FlipAxisDemo: View {
    let front: CGImage?
    let back: CGImage?
    let flip: Flip
    /// The front's pixel dimensions, used for layout the same way `FlippableCardView` does —
    /// no full decode needed just to size the card correctly within the square.
    let frontPixelSize: CGSize

    static let revolutionPeriod: TimeInterval = 5

    private var axis: FlipAxis? { FlipGeometry.axis(for: flip) }

    private var safeFrontPixelSize: CGSize {
        CGSize(width: max(frontPixelSize.width, 1), height: max(frontPixelSize.height, 1))
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                axisLine(boxSide: side)
                content(boxSide: side)
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(boxSide: CGFloat) -> some View {
        if let front, let axis {
            TimelineView(.animation) { timeline in
                let angle = FlipGeometry.continuousAngleDegrees(
                    elapsedSeconds: timeline.date.timeIntervalSinceReferenceDate,
                    period: Self.revolutionPeriod
                )
                faces(front: front, axis: axis, angleDegrees: angle, boxSide: boxSide)
            }
        } else {
            ProgressView()
        }
    }

    /// Always rendered underneath the card (see `ZStack` order above): the hinge line the
    /// card is rotating about, extended to the square's own edges.
    @ViewBuilder
    private func axisLine(boxSide: CGFloat) -> some View {
        if let axis {
            let (start, end) = FlipGeometry.axisLineEndpoints(axis: axis, boxSide: boxSide)
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(Color.blue.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        }
    }

    /// Mirrors `FlippableCardView.faces(fittedIn:)`: one scale from fitting the flip's
    /// bounding box into the square, both faces sized off that same scale so a hand flip's
    /// back keeps the front's dimensions swapped at identical area.
    private func faces(front: CGImage, axis: FlipAxis, angleDegrees: Double, boxSide: CGFloat) -> some View {
        let boundingSize = FlipGeometry.boundingSize(forFrontSize: safeFrontPixelSize, flip: flip)
        let scale = min(boxSide / boundingSize.width, boxSide / boundingSize.height)
        let frontSize = CGSize(width: safeFrontPixelSize.width * scale, height: safeFrontPixelSize.height * scale)
        let backSize = FlipGeometry.backSize(forFrontSize: frontSize, flip: flip)

        return ZStack {
            face(front, size: frontSize, angleDegrees: angleDegrees, axis: axis)
            if let back {
                face(back, size: backSize, angleDegrees: angleDegrees + 180, axis: axis)
            }
        }
        .frame(width: boxSide, height: boxSide)
    }

    private func face(_ cgImage: CGImage, size: CGSize, angleDegrees: Double, axis: FlipAxis) -> some View {
        Image(decorative: cgImage, scale: 1)
            .resizable()
            .frame(width: size.width, height: size.height)
            .modifier(FlipFace(angleDegrees: angleDegrees, axis: axis))
    }
}

// MARK: - Fields-pane flip-axis picker

/// The fields pane's flip chooser: `FlipAxisDemo` beside a native, vertically-stacked
/// radio-style `Picker` over `model.allowedFlips`. Thin over the model like every other
/// `CreatePostcardForm` section — this view only decodes the small preview images (the
/// `ScanThumbnail` cache pattern `PostcardStage`'s side cards and `DescribeWizard` also use)
/// and lays out the row; `CreatePostcardForm` gates mounting this on `model.back != nil`,
/// matching the picker's old stage-hosted visibility rule.
struct FlipAxisPicker: View {
    @Bindable var model: CreatePostcardModel
    let flipError: String?

    @State private var frontImage: CGImage?
    @State private var backImage: CGImage?

    private nonisolated static let previewMaxPixelSize: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                FlipAxisDemo(front: frontImage, back: backImage, flip: model.flip, frontPixelSize: frontPixelSize)
                    .frame(width: 120, height: 120)
                flipPicker
                Spacer(minLength: 0)
            }
            if let flipError {
                Label(flipError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .task(id: DecodeKey(front: model.front?.id, back: model.back?.id)) {
            await decodeFaces()
        }
    }

    private var frontPixelSize: CGSize {
        CGSize(width: model.front?.pixelWidth ?? 1, height: model.front?.pixelHeight ?? 1)
    }

    /// The title is a plain `Text` above the picker (rather than the picker's own label) and
    /// the picker itself `.labelsHidden()` — feeding "Flip axis:" as the `Picker`'s label instead
    /// makes macOS lay the label and its `.radioGroup` options out in one horizontal row; this
    /// is what actually stacks the title over a vertical column of options.
    private var flipPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Flip axis:")
                .foregroundStyle(.secondary)
            Picker("Flip axis:", selection: $model.flip) {
                ForEach(model.allowedFlips, id: \.self) { flip in
                    Text(flip.axisPickerLabel).tag(flip)
                }
            }
            .labelsHidden()
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #else
            .pickerStyle(.inline)
            #endif
        }
    }

    private struct DecodeKey: Equatable {
        var front: UUID?
        var back: UUID?
    }

    private func decodeFaces() async {
        guard let frontData = model.front?.data else {
            frontImage = nil
            backImage = nil
            return
        }
        let backData = model.back?.data
        let (front, back) = await Task.detached(priority: .utility) {
            (
                ScanThumbnail.decode(from: frontData, maxPixelSize: Self.previewMaxPixelSize),
                backData.flatMap { ScanThumbnail.decode(from: $0, maxPixelSize: Self.previewMaxPixelSize) }
            )
        }.value
        frontImage = front
        backImage = back
    }
}

/// Short flip-axis labels for the radio picker. `Flip` itself (Models.swift) carries no
/// display strings — its Go-mirrored cases are compared/serialized, never shown — so this
/// stays local to the one view that needs them.
private extension Flip {
    var axisPickerLabel: String {
        switch self {
        case .book: "Book"
        case .calendar: "Calendar"
        case .rightHand: "Right-hand"
        case .leftHand: "Left-hand"
        case .none: "No back"
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Book") {
    flipAxisDemoPreview(flip: .book)
}

#Preview("Calendar") {
    flipAxisDemoPreview(flip: .calendar)
}

#Preview("Right-hand") {
    flipAxisDemoPreview(flip: .rightHand)
}

#Preview("Left-hand") {
    flipAxisDemoPreview(flip: .leftHand)
}

#Preview("Picker row") {
    let model = CreatePostcardModel()
    try? model.setFront(data: flipAxisPreviewImageData(tint: (0.93, 0.90, 0.83)), filename: "front.png")
    try? model.setBack(data: flipAxisPreviewImageData(tint: (0.85, 0.88, 0.93)), filename: "back.png")
    return FlipAxisPicker(model: model, flipError: nil)
        .padding()
        .frame(width: 420)
}

/// Generated postcard-ish placeholders (border, "stamp" corner) so this preview needs no
/// bundled fixture image — `tint` differentiates front/back at a glance, matching
/// `PostcardStage`'s/`DescribeWizard`'s own preview-fixture helpers.
@MainActor
private func flipAxisDemoPreview(flip: Flip) -> some View {
    let front = flipAxisPreviewImageData(tint: (0.93, 0.90, 0.83))
    let back = flipAxisPreviewImageData(tint: (0.85, 0.88, 0.93))
    let frontCGImage = ScanThumbnail.decode(from: front, maxPixelSize: 400)
    let backCGImage = ScanThumbnail.decode(from: back, maxPixelSize: 400)
    return FlipAxisDemo(
        front: frontCGImage,
        back: backCGImage,
        flip: flip,
        frontPixelSize: CGSize(width: 900, height: 600)
    )
    .frame(width: 160, height: 160)
    .padding()
}

private func flipAxisPreviewImageData(width: Int = 900, height: Int = 600, tint: (Double, Double, Double)) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return Data() }

    let w = CGFloat(width)
    let h = CGFloat(height)

    context.setFillColor(CGColor(red: tint.0, green: tint.1, blue: tint.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: w, height: h))

    context.setStrokeColor(CGColor(red: 0.55, green: 0.42, blue: 0.3, alpha: 1))
    context.setLineWidth(6)
    context.stroke(CGRect(x: 20, y: 20, width: w - 40, height: h - 40))

    context.setFillColor(CGColor(red: 0.75, green: 0.2, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: w - 160, y: 40, width: 100, height: 130))

    guard let cgImage = context.makeImage() else { return Data() }
    let mutableData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
        return Data()
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
    return mutableData as Data
}
#endif
