// SKYFORGE — Apache-2.0
// Payload and weight-and-balance. Loads (passengers, cargo, fuel) sit at stations with an arm, the
// combined centre of gravity moves with the load, and the aircraft's mass and inertia follow it.
// The aerodynamic coefficients were estimated at a reference CG; moving the CG aft reduces the
// pitch stability (cmAlpha) and moving it forward increases it, using a simple static-margin scaling.
import Foundation

public struct PayloadStation: Sendable, Codable, Equatable {
    public var name: String
    public var mass: Double          // kg
    /// Longitudinal arm (m) relative to the reference CG, positive forward and negative aft.
    public var arm: Double

    public init(name: String, mass: Double, arm: Double) {
        self.name = name
        self.mass = mass.isFinite ? max(0, mass) : 0
        self.arm = arm.isFinite ? arm : 0
    }
}

public struct WeightAndBalance: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case withinEnvelope, forwardOfLimit, aftOfLimit }

    public var emptyMass: Double
    /// CG of the empty aircraft (m, relative to the reference CG).
    public var emptyCGArm: Double
    public var stations: [PayloadStation]
    /// Forward-most and aft-most CG limits (m, same sign convention as the arms: forward positive).
    public var forwardLimit: Double
    public var aftLimit: Double
    /// Mean aerodynamic chord (m) used to scale the stability change.
    public var chord: Double

    public init(emptyMass: Double, emptyCGArm: Double = 0, stations: [PayloadStation] = [],
                forwardLimit: Double = 0.12, aftLimit: Double = -0.18, chord: Double = 1.5) {
        self.emptyMass = emptyMass.isFinite ? max(1, emptyMass) : 1
        self.emptyCGArm = emptyCGArm.isFinite ? emptyCGArm : 0
        self.stations = stations
        self.forwardLimit = forwardLimit
        self.aftLimit = aftLimit
        self.chord = chord.isFinite && chord > 0 ? chord : 1.5
    }

    /// Mean loaded mass (kg): empty mass plus all station loads.
    public var totalMass: Double { emptyMass + stations.reduce(0) { $0 + $1.mass } }

    /// Combined CG arm (m) of the loaded aircraft.
    public var cgArm: Double {
        let moment = emptyMass * emptyCGArm + stations.reduce(0) { $0 + $1.mass * $1.arm }
        return moment / totalMass
    }

    public var status: Status {
        let x = cgArm
        if x > forwardLimit { return .forwardOfLimit }
        if x < aftLimit { return .aftOfLimit }
        return .withinEnvelope
    }

    /// Returns the aircraft configuration with this load applied: mass, inertia (scaled with mass)
    /// and pitch stability (scaled by the CG shift from the reference).
    public func applied(to config: AircraftConfig) -> AircraftConfig {
        var c = config
        let m = totalMass
        let ratio = m / max(config.mass, 1)
        c.mass = m
        c.inertia = config.inertia * ratio
        // Fraction of the chord the CG sits aft (+) or forward (-) of the reference.
        let shift = -cgArm / chord
        let stabilityScale = min(1.5, max(0.3, 1 - 2 * shift))
        c.aero.cmAlpha = config.aero.cmAlpha * stabilityScale
        return c
    }
}
