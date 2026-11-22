// SKYFORGE — Apache-2.0
// Performance and pattern geometry for AI traffic. Speeds come from each type's own stall speed (lift
// equation with its CLmax), climb rate from its specific power, and turns from a fixed 600 m radius, so
// a 1 kg trainer and a 4.5 t jet both fit the same pattern. Patterns are right-hand unless `leftTraffic`.
import Foundation
import SFFlightModel

public enum TrafficPerformance {
    public static let gravity = 9.806_65
    /// Aircraft at or above this mass (kg) shed wake vortices.
    public static let heavyMass = 2_000.0
    /// Constant turn radius for every type (m).
    public static let turnRadius = 600.0
    /// Slowest turn rate (rad/s), so a very slow aircraft still turns.
    public static let minimumTurnRate = 0.03
    /// Steepest descent the guidance commands (m/s).
    public static let maxDescentRate = 5.0
    /// Acceleration on the runway for takeoff and rollout (m/s^2).
    public static let groundAcceleration = 2.0
    /// Rate at which speed changes toward its target (m/s^2).
    public static let speedChangeRate = 1.5

    /// Speeds for one type at one field (m/s).
    public struct Speeds: Sendable, Equatable {
        /// Rotation speed for takeoff.
        public var rotate: Double
        /// Climb-out speed.
        public var climb: Double
        /// Base and final approach speed (flaps set).
        public var approach: Double
        /// Downwind and inbound speed (clean).
        public var downwind: Double

        public init(rotate: Double, climb: Double, approach: Double, downwind: Double) {
            self.rotate = rotate
            self.climb = climb
            self.approach = approach
            self.downwind = downwind
        }
    }

    public static func isHeavy(_ config: AircraftConfig) -> Bool { config.mass >= heavyMass }

    /// Stall speed (m/s) from the lift equation: Vs = sqrt(2 W / (rho S CLmax)).
    public static func stallSpeed(_ config: AircraftConfig, density: Double, flaps: Bool) -> Double {
        let cLMax = max(flaps ? config.aero.cLMaxFlaps : config.aero.cLMaxClean, 0.1)
        let rho = max(density, 1e-6)
        let area = max(config.wingArea, 1)
        return (2 * config.mass * gravity / (rho * area * cLMax)).squareRoot()
    }

    /// Speeds for a type at a field density (kg/m^3).
    public static func speeds(_ config: AircraftConfig, density: Double) -> Speeds {
        let vClean = stallSpeed(config, density: density, flaps: false)
        let vFlaps = stallSpeed(config, density: density, flaps: true)
        return Speeds(rotate: 1.15 * vClean, climb: 1.3 * vClean, approach: 1.3 * vFlaps, downwind: 1.3 * vClean)
    }

    /// Sustainable climb rate (m/s) from specific power, kept between 2 and 12 m/s.
    public static func maxClimbRate(_ config: AircraftConfig) -> Double {
        let specificPower = config.maxPower / (max(config.mass, 1) * gravity)
        return min(12, max(2, 0.25 * specificPower))
    }

    /// Turn rate (rad/s) at a speed for the fixed turn radius.
    public static func turnRate(speed: Double) -> Double {
        max(minimumTurnRate, max(speed, 0) / turnRadius)
    }

    /// Angle wrapped to (-pi, pi].
    public static func wrapAngle(_ angle: Double) -> Double {
        var x = angle.truncatingRemainder(dividingBy: 2 * Double.pi)
        if x > Double.pi { x -= 2 * Double.pi }
        if x <= -Double.pi { x += 2 * Double.pi }
        return x
    }

    /// Heading after turning from `current` toward `desired` at most `rate * dt`.
    public static func turn(from current: Double, toward desired: Double, rate: Double, dt: Double) -> Double {
        let difference = wrapAngle(desired - current)
        let step = max(-rate * dt, min(rate * dt, difference))
        return wrapAngle(current + step)
    }
}

/// Fixed pattern and departure geometry for one runway, in runway coordinates (m).
public struct TrafficPatternGeometry: Sendable, Equatable {
    /// Left-hand pattern when true; right-hand otherwise.
    public var leftTraffic: Bool
    /// Pattern altitude above the runway: 305 m, or 1,000 ft.
    public var patternAltitude: Double = 305
    /// Lateral offset of the downwind leg.
    public var downwindOffset: Double = 1_000
    /// Along-track position where the downwind leg starts (the pattern entry).
    public var downwindStart: Double = 1_200
    /// Altitude at the downwind-to-base turn.
    public var downwindEndAltitude: Double = 200
    /// Along-track position of the base-to-final turn, and of the final fix. Negative: before the threshold.
    public var baseCorner: Double = -1_000
    /// Aim point for touchdown.
    public var touchdownAlong: Double = 300
    /// Departure waypoints (along, right, up). The last one ends the departure.
    public var departureRoute: [SIMD3<Double>] = [
        SIMD3(1_500, 0, 250),
        SIMD3(5_000, 0, 400),
        SIMD3(9_000, 0, 500),
    ]

    public init(leftTraffic: Bool = false) {
        self.leftTraffic = leftTraffic
    }

    /// +1 for right-hand traffic, -1 for left.
    public var side: Double { leftTraffic ? -1 : 1 }

    /// Altitude of the final fix: a 3 degree glide path back to the base corner.
    public var finalFixAltitude: Double {
        tan(3 * Double.pi / 180) * (touchdownAlong - baseCorner)
    }

    /// Runway-frame waypoint (along, right, up) an arrival in `phase` flies toward.
    public func waypoint(for phase: TrafficPhase) -> SIMD3<Double> {
        switch phase {
        case .inbound, .extended:
            return SIMD3(downwindStart, side * downwindOffset, patternAltitude)
        case .downwind:
            return SIMD3(baseCorner, side * downwindOffset, downwindEndAltitude)
        case .base:
            return SIMD3(baseCorner, 0, finalFixAltitude)
        case .final, .landing, .holdShort, .takeoffRoll, .departing, .complete:
            return SIMD3(touchdownAlong, 0, 0)
        }
    }
}
