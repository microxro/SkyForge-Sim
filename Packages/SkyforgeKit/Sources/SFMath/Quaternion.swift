// SKYFORGE — Apache-2.0
import Foundation
/// A unit quaternion (w + xi + yj + zk) in Double precision, used for attitude.
public struct Quaternion: Sendable, Equatable {
    public var w: Double
    public var v: SIMD3<Double>

    public init(w: Double, v: SIMD3<Double>) { self.w = w; self.v = v }
    public static let identity = Quaternion(w: 1, v: .zero)

    public init(axis: SIMD3<Double>, angle: Double) {
        let n = normalize(axis)
        w = cos(angle / 2)
        v = n * sin(angle / 2)
    }

    /// Aerospace 3-2-1 Euler (yaw psi, pitch theta, roll phi), body-from-NED convention.
    public init(roll: Double, pitch: Double, yaw: Double) {
        let cr = cos(roll / 2), sr = sin(roll / 2)
        let cp = cos(pitch / 2), sp = sin(pitch / 2)
        let cy = cos(yaw / 2), sy = sin(yaw / 2)
        w = cr * cp * cy + sr * sp * sy
        v = SIMD3(sr * cp * cy - cr * sp * sy,
                  cr * sp * cy + sr * cp * sy,
                  cr * cp * sy - sr * sp * cy)
    }

    public var euler: (roll: Double, pitch: Double, yaw: Double) {
        let roll = atan2(2 * (w * v.x + v.y * v.z), 1 - 2 * (v.x * v.x + v.y * v.y))
        let s = max(-1.0, min(1.0, 2 * (w * v.y - v.z * v.x)))
        let pitch = asin(s)
        let yaw = atan2(2 * (w * v.z + v.x * v.y), 1 - 2 * (v.y * v.y + v.z * v.z))
        return (roll, pitch, yaw)
    }

    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        Quaternion(w: a.w * b.w - dot(a.v, b.v), v: b.v * a.w + a.v * b.w + cross(a.v, b.v))
    }

    public var conjugate: Quaternion { Quaternion(w: w, v: -v) }
    public var norm: Double { (w * w + dot(v, v)).squareRoot() }
    public var normalized: Quaternion {
        let n = norm
        return n > 0 ? Quaternion(w: w / n, v: v / n) : .identity
    }

    /// Rotates a vector by this quaternion (q * v * q^-1).
    public func rotate(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let t = cross(v, p) * 2
        return p + t * w + cross(v, t)
    }

    /// Time derivative for body angular rate omega (rad/s): qdot = 0.5 * q * (0, omega).
    public func derivative(bodyRate omega: SIMD3<Double>) -> Quaternion {
        let r = self * Quaternion(w: 0, v: omega)
        return Quaternion(w: 0.5 * r.w, v: 0.5 * r.v)
    }
}
