import Foundation

/// Unit quaternion rotation, Hamilton convention. `a * b` applies `b` first, then `a`.
public struct Quat: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    public static let identity = Quat(x: 0, y: 0, z: 0, w: 1)

    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(
            x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    public static func axisAngle(_ axis: Vec3, _ angle: Double) -> Quat {
        let half = angle * 0.5
        let s = sin(half)
        let a = axis.normalized
        return Quat(x: a.x * s, y: a.y * s, z: a.z * s, w: cos(half))
    }

    /// Rotation for a heading (yaw about +z) followed by a pitch (about the body +y axis).
    /// Body forward is +x; positive pitch nose-up.
    public static func yawPitch(yaw: Double, pitch: Double) -> Quat {
        axisAngle(Vec3(0, 0, 1), yaw) * axisAngle(Vec3(0, 1, 0), -pitch)
    }

    public var normalized: Quat {
        let n = (x * x + y * y + z * z + w * w).squareRoot()
        guard n > 0 else { return .identity }
        return Quat(x: x / n, y: y / n, z: z / n, w: w / n)
    }

    public func dot(_ o: Quat) -> Double {
        x * o.x + y * o.y + z * o.z + w * o.w
    }

    /// Rotates a vector by this quaternion.
    public func rotate(_ v: Vec3) -> Vec3 {
        let u = Vec3(x, y, z)
        let t = u.cross(v) * 2
        return v + t * w + u.cross(t)
    }

    public static func slerp(_ a: Quat, _ b: Quat, _ t: Double) -> Quat {
        var target = b
        var d = a.dot(b)
        if d < 0 {
            target = Quat(x: -b.x, y: -b.y, z: -b.z, w: -b.w)
            d = -d
        }
        if d > 0.9995 {
            return Quat(
                x: a.x + (target.x - a.x) * t,
                y: a.y + (target.y - a.y) * t,
                z: a.z + (target.z - a.z) * t,
                w: a.w + (target.w - a.w) * t
            ).normalized
        }
        let theta = acos(min(d, 1)) * t
        let perp = Quat(
            x: target.x - a.x * d,
            y: target.y - a.y * d,
            z: target.z - a.z * d,
            w: target.w - a.w * d
        ).normalized
        let c = cos(theta)
        let s = sin(theta)
        return Quat(
            x: a.x * c + perp.x * s,
            y: a.y * c + perp.y * s,
            z: a.z * c + perp.z * s,
            w: a.w * c + perp.w * s
        )
    }
}
