import CoreMotion
import Foundation

/// Reads the gyroscope and accelerometer to tell when the phone is being held still (time to read)
/// and when it has moved away from where the still was taken (time to aim again).
/// Needs no permission. Delivers on the main queue.
final class MotionMonitor {
    struct Reading {
        /// Seconds the phone has been held still; 0 while it moves.
        var steadyFor: TimeInterval
        /// Degrees the phone has turned since `mark()`.
        var degreesFromMark: Double
        /// A deliberate move: a quick turn or a jolt, not hand tremor or a tap on the screen.
        var movedSharply: Bool
        /// More than a hand's tremor: a moving car, a walk. Long exposures blur.
        var shaking: Bool
    }

    // Tuning, generous on purpose: an arm held out over a menu shakes more than a phone at rest.
    // (The app also locks when the camera sees the same text three frames running.)
    static let stillRate = 0.25 // rad/s
    static let stillAcceleration = 0.12 // g
    static let sharpTurnRate = 0.9 // rad/s: re-aiming, not drifting
    static let sharpJolt = 0.35 // g
    static let shakeRate = 0.35 // rad/s
    static let shakeAcceleration = 0.15 // g

    var onReading: ((Reading) -> Void)?

    private let manager = CMMotionManager()
    private var steadySince: TimeInterval?
    private var reference: CMAttitude?
    private var rate = 0.0 // smoothed, so a tap on the screen isn't a "move"
    private var acceleration = 0.0

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.process(motion)
        }
    }

    /// Remember the current orientation; `degreesFromMark` measures from here.
    func mark() {
        reference = manager.deviceMotion?.attitude.copy() as? CMAttitude
    }

    private func process(_ motion: CMDeviceMotion) {
        let r = motion.rotationRate, a = motion.userAcceleration
        rate = rate * 0.7 + (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot() * 0.3
        acceleration = acceleration * 0.7 + (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() * 0.3

        let still = rate < Self.stillRate && acceleration < Self.stillAcceleration
        steadySince = still ? (steadySince ?? motion.timestamp) : nil

        var degrees = 0.0
        if let reference, let attitude = motion.attitude.copy() as? CMAttitude {
            attitude.multiply(byInverseOf: reference)
            degrees = 2 * acos(min(1, abs(attitude.quaternion.w))) * 180 / .pi
        }
        onReading?(Reading(
            steadyFor: steadySince.map { motion.timestamp - $0 } ?? 0,
            degreesFromMark: degrees,
            movedSharply: rate > Self.sharpTurnRate || acceleration > Self.sharpJolt,
            shaking: rate > Self.shakeRate || acceleration > Self.shakeAcceleration
        ))
    }
}
