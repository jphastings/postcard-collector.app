import SwiftUI

/// A thin circular track, filled clockwise from the top to `fraction`: a download's progress,
/// drawn the size of the icons beside it rather than as a system spinner or bar with its own
/// intrinsic size and padding. The watch's collection list and the iCloud rows of the phone's
/// and Mac's collection list both use it.
struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0.03), 1))
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.5)
    }
}

/// The same track with a quarter arc sweeping round it, for a download that's been asked for
/// but hasn't reported its progress yet. Driven by the timeline rather than a repeating
/// animation, which list rows can restart or drop as they re-render.
struct SpinningRing: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(turns * 360))
            }
            .padding(1.5)
        }
    }
}
