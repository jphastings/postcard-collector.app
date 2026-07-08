import Foundation
import Observation

#if os(iOS)
import CoreMotion
import UIKit
#elseif os(watchOS)
import CoreMotion
import WatchKit
#elseif os(macOS)
import AppKit
#endif

/// Drives `ParallaxGeometry`'s tilt from the platform's live input: `CMMotionManager`
/// device attitude on iOS, pointer hover on macOS. Scoped to exactly one card's lifetime —
/// `FlippableCardView` calls `start()`/`stop()` from appear/disappear and `scenePhase`, so
/// the motion manager never runs anywhere outside the detail view, or while backgrounded.
@MainActor
@Observable
final class ParallaxModel {
    private(set) var tilt: ParallaxGeometry.Tilt = .zero

    private var reduceMotion: Bool {
        #if os(iOS)
        UIAccessibility.isReduceMotionEnabled
        #elseif os(watchOS)
        WKAccessibilityIsReduceMotionEnabled()
        #elseif os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    #if os(iOS) || os(watchOS)
    private let motionManager = CMMotionManager()
    private var referencePitch: Double?
    private var referenceRoll: Double?

    /// Fraction the reference attitude eases toward the current one on every update, so a
    /// phone held at a steady angle slowly re-centres instead of pinning the tilt at one
    /// extreme forever (see `ParallaxGeometry.decay`).
    private static let referenceDecayPerUpdate = 0.02

    func start() {
        guard !reduceMotion, motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        referencePitch = nil
        referenceRoll = nil
        #if os(watchOS)
        // A gentler update rate than iOS's ~33ms — the watch's smaller screen and slower
        // GPU don't need the extra samples, and this is friendlier to battery.
        motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
        #else
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        #endif
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        referencePitch = nil
        referenceRoll = nil
        tilt = .zero
    }

    private func handle(_ motion: CMDeviceMotion) {
        guard !reduceMotion else {
            tilt = .zero
            return
        }

        let pitch = motion.attitude.pitch
        let roll = motion.attitude.roll

        // First sample after start(): rest the reference exactly on the current attitude,
        // so the card starts flat however the phone happens to be held.
        let newReferencePitch = ParallaxGeometry.decay(reference: referencePitch ?? pitch, towardCurrent: pitch, factor: Self.referenceDecayPerUpdate)
        let newReferenceRoll = ParallaxGeometry.decay(reference: referenceRoll ?? roll, towardCurrent: roll, factor: Self.referenceDecayPerUpdate)
        referencePitch = newReferencePitch
        referenceRoll = newReferenceRoll

        tilt = ParallaxGeometry.tilt(pitchDelta: pitch - newReferencePitch, rollDelta: roll - newReferenceRoll)
    }
    #elseif os(macOS)
    func start() {}

    func stop() {
        tilt = .zero
    }

    /// `location` is `nil` when the pointer has left the card; callers should wrap that
    /// call in `withAnimation` to ease the tilt back to zero rather than snapping it.
    func updateHover(location: CGPoint?, in size: CGSize) {
        guard let location else {
            tilt = .zero
            return
        }
        tilt = ParallaxGeometry.tilt(hoverLocation: location, in: size, reduceMotion: reduceMotion)
    }
    #endif
}
