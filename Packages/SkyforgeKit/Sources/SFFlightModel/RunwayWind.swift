// SKYFORGE — Apache-2.0
// Runway wind components. The air-mass velocity (NED) is split into a headwind and a crosswind for a
// given runway heading, using the standard convention: headwind is positive when the air moves toward
// the aircraft's nose along the runway, crosswind is positive when the wind comes from the right.
import Foundation

public struct RunwayWind: Sendable, Equatable {
    /// Headwind (m/s), positive into the nose, negative tailwind.
    public let headwind: Double
    /// Crosswind (m/s), positive from the right, negative from the left.
    public let crosswind: Double

    public init(headwind: Double, crosswind: Double) {
        self.headwind = headwind.isFinite ? headwind : 0
        self.crosswind = crosswind.isFinite ? crosswind : 0
    }

    /// Components of an air-mass velocity (NED, m/s) relative to a runway heading (rad, clockwise from north).
    public static func components(airmassNED w: SIMD3<Double>, runwayHeadingRad h: Double) -> RunwayWind {
        let along = SIMD2<Double>(cos(h), sin(h))
        let right = SIMD2<Double>(-sin(h), cos(h))
        let wind = SIMD2<Double>(w.x, w.y)
        return RunwayWind(headwind: -(wind.x * along.x + wind.y * along.y),
                          crosswind: -(wind.x * right.x + wind.y * right.y))
    }

    /// True when the crosswind magnitude is within a limit (m/s). Non-finite limits never pass.
    public func withinCrosswindLimit(_ limit: Double) -> Bool {
        limit.isFinite && abs(crosswind) <= limit
    }
}
