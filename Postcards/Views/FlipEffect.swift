import SwiftUI

/// One face of the flipping card: a 3D rotation about a `FlipAxis` (with a fixed
/// perspective matching the reference CSS's `perspective(1000px)`, scaled to SwiftUI's
/// 0...1 unit) plus backface hiding.
///
/// `Animatable` is the load-bearing part: `animatableData` makes SwiftUI interpolate
/// `angleDegrees` and re-evaluate `body` every frame of a `withAnimation` transaction.
/// Visibility is then a step function of the LIVE angle — `FlipGeometry.showsFront`
/// flips exactly at the 90° edge-on frame mid-animation — rather than an animated
/// opacity between the transaction's endpoints, which would cross-fade the two sides
/// like a ghost instead of hiding the averted face like a physical card.
///
/// (Internal rather than private so a rendering harness in the same module can drive it
/// at fixed angles; the pure decision function lives in `FlipGeometry` for unit tests.)
struct FlipFace: ViewModifier, Animatable {
    /// This face's own rotation (the back face is constructed with the shared flip angle
    /// + 180°, so each face tests its own normal against the viewer).
    var angleDegrees: Double
    var axis: FlipAxis

    var animatableData: Double {
        get { angleDegrees }
        set { angleDegrees = newValue }
    }

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(angleDegrees),
                axis: (x: axis.x, y: axis.y, z: axis.z),
                perspective: 0.5
            )
            .opacity(FlipGeometry.showsFront(atDegrees: angleDegrees) ? 1 : 0)
    }
}

/// A postcard that tap-flips between its front and back, 3D-rotating about the axis
/// appropriate to its `Flip` type (see `FlipGeometry`). Cards with `flip == .none`, or
/// with no back image, are shown flat with no tap interaction.
///
/// Both faces stay mounted in one ZStack the whole time (no pop-in latency) and share a
/// single display scale derived from the front: a hand flip's back renders at exactly the
/// front's dimensions swapped — same area, same physical card — centred on the same point
/// so the diagonal turn carries one rectangle onto the other. The view reserves the
/// bounding box of both orientations (a square, for hand flips) so neither overflows.
struct FlippableCardView: View {
    let front: CGImage
    let back: CGImage?
    let flip: Flip
    /// The front's pixel dimensions (from `CardSummary.frontPxW/H`), used for layout so
    /// no image decode is needed to size the card.
    let frontPixelSize: CGSize
    /// Whether this view attaches its own single-tap-to-flip gesture. `WatchCardView` sets
    /// this to `false` so it can put its own single-tap(flip)/double-tap(zoom) recognizers
    /// on one container without a second, competing tap gesture nested inside. Defaults to
    /// `true`, preserving every existing iOS/macOS caller's behavior unchanged.
    var tapToFlip: Bool = true
    /// When provided, the flip angle mirrors this binding instead of only reacting to the
    /// internal tap gesture — set by an external owner (`WatchCardView`) that flips the
    /// card from its own gesture handler. `nil` (the default) preserves today's fully
    /// self-contained behavior.
    var isFlipped: Binding<Bool>? = nil

    @State private var angleDegrees: Double
    @State private var parallax = ParallaxModel()
    @Environment(\.scenePhase) private var scenePhase

    init(
        front: CGImage,
        back: CGImage?,
        flip: Flip,
        frontPixelSize: CGSize,
        initialAngleDegrees: Double = 0,
        tapToFlip: Bool = true,
        isFlipped: Binding<Bool>? = nil
    ) {
        self.front = front
        self.back = back
        self.flip = flip
        self.frontPixelSize = CGSize(
            width: max(frontPixelSize.width, 1),
            height: max(frontPixelSize.height, 1)
        )
        self.tapToFlip = tapToFlip
        self.isFlipped = isFlipped
        _angleDegrees = State(initialValue: isFlipped?.wrappedValue == true ? 180 : initialAngleDegrees)
    }

    private var axis: FlipAxis? { back != nil ? FlipGeometry.axis(for: flip) : nil }

    private var boundingSize: CGSize {
        FlipGeometry.boundingSize(forFrontSize: frontPixelSize, flip: flip)
    }

    var body: some View {
        GeometryReader { proxy in
            faces(fittedIn: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
                #if os(macOS)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        parallax.updateHover(location: location, in: proxy.size)
                    case .ended:
                        withAnimation(.easeOut(duration: 0.4)) {
                            parallax.updateHover(location: nil, in: proxy.size)
                        }
                    }
                }
                #endif
        }
        .aspectRatio(boundingSize.width / boundingSize.height, contentMode: .fit)
        .accessibilityAddTraits(axis == nil ? [] : .isButton)
        .accessibilityLabel(
            FlipGeometry.showsFront(atDegrees: angleDegrees) ? "Front of postcard" : "Back of postcard"
        )
        .onAppear { parallax.start() }
        .onDisappear { parallax.stop() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                parallax.start()
            } else {
                parallax.stop()
            }
        }
        .onChange(of: isFlipped?.wrappedValue) { _, newValue in
            guard let newValue else { return }
            withAnimation(.easeInOut(duration: 1)) {
                angleDegrees = newValue ? 180 : 0
            }
        }
    }

    @ViewBuilder
    private func faces(fittedIn available: CGSize) -> some View {
        // ONE scale, from fitting the bounding box (not each side independently): both
        // sides display at this same scale, so a hand flip's portrait back has exactly
        // the landscape front's area with the dimensions swapped.
        let scale = min(available.width / boundingSize.width, available.height / boundingSize.height)
        let frontSize = CGSize(width: frontPixelSize.width * scale, height: frontPixelSize.height * scale)
        let backSize = FlipGeometry.backSize(forFrontSize: frontSize, flip: flip)
        let axis = axis ?? FlipAxis(x: 0, y: 1, z: 0)

        let stack = ZStack {
            face(front, size: frontSize, angleDegrees: angleDegrees, axis: axis)
            if let back, self.axis != nil {
                face(back, size: backSize, angleDegrees: angleDegrees + 180, axis: axis)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Parallax tilts both faces together as one rigid object, as an extra rotation on
        // top of the flip rather than folded into `angleDegrees` — it never touches the
        // FlipFace modifiers above, so FlipGeometry.showsFront's hard 90° backface cut still
        // only ever sees the live flip angle, untouched by however the card is tilted.
        .rotation3DEffect(.degrees(parallax.tilt.y), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(parallax.tilt.x), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .shadow(
            color: .black.opacity(0.25),
            radius: 16,
            x: 8 + CGFloat(parallax.tilt.x) * Self.shadowPointsPerDegree,
            y: 12 + CGFloat(parallax.tilt.y) * Self.shadowPointsPerDegree
        )
        .contentShape(Rectangle())

        // Only attach the internal recognizer when this view owns tap-to-flip: leaving it
        // attached-but-a-no-op (rather than omitted) when `tapToFlip` is false would still
        // let it capture the touch, fighting whatever single/double-tap gestures an external
        // owner (e.g. `WatchCardView`) attaches to the same container.
        if tapToFlip {
            stack.onTapGesture {
                guard self.axis != nil else { return }
                withAnimation(.easeInOut(duration: 1)) {
                    angleDegrees += 180
                }
            }
        } else {
            stack
        }
    }

    /// How many extra shadow points shift per degree of tilt — a cheap way to sell the
    /// parallax without a second shadow layer or per-frame geometry.
    private static let shadowPointsPerDegree: CGFloat = 1.5

    private func face(_ cgImage: CGImage, size: CGSize, angleDegrees: Double, axis: FlipAxis) -> some View {
        Image(decorative: cgImage, scale: 1)
            .resizable()
            .frame(width: size.width, height: size.height)
            .modifier(FlipFace(angleDegrees: angleDegrees, axis: axis))
    }
}
