// SKYFORGE — Apache-2.0
// Stall-and-spin assessment. It detects a developed spin from the aircraft's own state (stalled angle
// of attack plus sustained yaw and roll rates) and suggests the standard recovery control inputs:
// opposite rudder to stop the yaw, then forward elevator to unstall. This is a detector and a
// recovery aid. It does not replace the aerodynamic model, and the recovery is only effective when the
// airframe has the rudder and elevator authority to break the autorotation.
import Foundation

public struct SpinAssessment: Sendable, Equatable {
    /// True when the aircraft is stalled and rotating about its yaw axis at a sustained rate.
    public let inSpin: Bool
    /// Spin direction: +1 yawing right, -1 yawing left, 0 when not spinning.
    public let direction: Double
    /// Suggested rudder input (-1…1) to oppose the spin. 0 when not spinning.
    public let recoveryRudder: Double
    /// Suggested elevator input (-1…1): forward (negative) to unstall. 0 when not spinning.
    public let recoveryElevator: Double

    /// Yaw rate (rad/s) above which a stalled aircraft counts as spinning.
    public static let spinYawRate = 0.35
    /// Roll rate (rad/s) above which a stalled aircraft counts as spinning (autorotation rolls too).
    public static let spinRollRate = 0.25

    public static func assess(stalled: Bool, bodyRates w: SIMD3<Double>) -> SpinAssessment {
        let p = w.x, r = w.z
        guard stalled, p.isFinite, r.isFinite else {
            return SpinAssessment(inSpin: false, direction: 0, recoveryRudder: 0, recoveryElevator: 0)
        }
        guard abs(r) >= spinYawRate, abs(p) >= spinRollRate || abs(r) >= 2 * spinYawRate else {
            return SpinAssessment(inSpin: false, direction: 0, recoveryRudder: 0, recoveryElevator: 0)
        }
        let dir: Double = r > 0 ? 1 : -1
        return SpinAssessment(inSpin: true, direction: dir, recoveryRudder: -dir, recoveryElevator: -1)
    }
}
