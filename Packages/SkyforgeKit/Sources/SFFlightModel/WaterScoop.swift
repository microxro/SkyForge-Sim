// SKYFORGE — Apache-2.0
// Water scooping for amphibious and firefighting aircraft. The hull skims the water at planing speed
// with the scoop door open, and the intake takes in water at a rate set by the intake area, the
// speed and the capture efficiency: mdot = rho_water * A * V * eta. The tank fills to capacity, and
// the open door adds drag while scooping. These are engineering estimates for the physics, not data
// from any real aircraft.
import Foundation

public struct WaterScoop: Sendable, Equatable {
    /// Intake area of the scoop (m^2).
    public var intakeArea: Double = 0.025
    /// Fraction of the intake flow captured into the tank.
    public var efficiency: Double = 0.7
    /// Speed band (m/s) in which the hull is planing and the scoop can take water.
    public var minSpeed: Double = 30
    public var maxSpeed: Double = 45
    /// Height above the water (m) below which the hull counts as skimming.
    public var skimHeight: Double = 1.5
    /// Tank capacity (kg).
    public var capacity: Double = 6_000
    /// Equivalent flat-plate drag area (m^2) of the open door while scooping.
    public var openDragArea: Double = 0.12
    /// Whether the scoop door is open (the pilot's control).
    public var doorOpen: Bool = false
    /// Water in the tank (kg).
    public private(set) var load: Double = 0

    public static let waterDensity = 1_000.0

    public struct Result: Sendable, Equatable {
        /// Water taken in this step (kg).
        public var massGain: Double
        /// True when the scoop took water this step.
        public var scooping: Bool
    }

    public init() {}

    /// True when the door is open, the hull is on the water at planing speed and skimming height,
    /// and the tank is not full.
    public func isScooping(speed: Double, heightAboveWater: Double, onWater: Bool) -> Bool {
        doorOpen && onWater && speed.isFinite && heightAboveWater.isFinite
            && speed >= minSpeed && speed <= maxSpeed && heightAboveWater <= skimHeight
            && load < capacity
    }

    /// Advances the tank by `dt` seconds and returns the water taken in.
    public mutating func step(dt: Double, speed: Double, heightAboveWater: Double, onWater: Bool) -> Result {
        guard dt.isFinite, dt > 0, isScooping(speed: speed, heightAboveWater: heightAboveWater, onWater: onWater) else {
            return Result(massGain: 0, scooping: false)
        }
        let flow = Self.waterDensity * intakeArea * speed * efficiency
        let gain = min(flow * dt, capacity - load)
        load += gain
        return Result(massGain: gain, scooping: true)
    }

    /// Extra drag (N) from the open door while scooping; zero otherwise.
    public func scoopDrag(airDensity: Double, speed: Double, scooping: Bool) -> Double {
        guard scooping, airDensity.isFinite, airDensity > 0, speed.isFinite else { return 0 }
        return 0.5 * airDensity * speed * speed * openDragArea
    }

    /// Dumps the whole tank (a drop on a fire) and returns the water released (kg).
    public mutating func release() -> Double {
        let dumped = load
        load = 0
        return dumped
    }
}
