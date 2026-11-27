import Foundation

public struct Vec3: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    public static func + (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    public static func - (lhs: Vec3, rhs: Vec3) -> Vec3 {
        Vec3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    public static func * (lhs: Vec3, rhs: Double) -> Vec3 {
        Vec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    public static func * (lhs: Double, rhs: Vec3) -> Vec3 {
        rhs * lhs
    }

    public func dot(_ o: Vec3) -> Double {
        x * o.x + y * o.y + z * o.z
    }

    public func cross(_ o: Vec3) -> Vec3 {
        Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }

    public var length: Double {
        (x * x + y * y + z * z).squareRoot()
    }

    /// Unit vector in the same direction, or zero when the length is zero.
    public var normalized: Vec3 {
        let l = length
        return l > 0 ? self * (1 / l) : self
    }

    public func lerp(to other: Vec3, t: Double) -> Vec3 {
        self + (other - self) * t
    }
}
