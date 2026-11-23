// SKYFORGE — Apache-2.0
// Flight envelope: load factor, Mach number, a fly-by-wire limiter for the military types and a
// monitor that raises cockpit warnings and decides when an airframe is overstressed.
import Foundation
import SFMath
import SFAtmosphere
import SFFlightModel

public enum EnvelopeMath {
    /// Normal load factor (g, +1 in level flight) from the model's body force, with gravity removed.
    /// On the ground the gear force balances weight, so this reads about +1.
    public static func loadFactor(state: AircraftState, outputs: FlightOutputs, config: AircraftConfig) -> Double {
        let weight = config.mass * ISA.g0
        let gravityBody = state.attitude.conjugate.rotate(SIMD3(0, 0, weight))
        let nz = -(outputs.forceBody.z - gravityBody.z) / weight
        return nz.isFinite ? nz : 1
    }

    public static func mach(trueAirspeed v: Double, altitudeMSL: Double, temperatureOffset: Double = 0) -> Double {
        let a = ISA.state(geometricAltitude: altitudeMSL, temperatureOffset: temperatureOffset).speedOfSound
        return v / max(1, a)
    }
}

/// Fly-by-wire pitch limiter: keeps load factor and angle of attack inside the limits.
///
/// The model has no structural or compressibility limits, and a jet at 250 m/s could otherwise pull
/// 20 g. The limiter restricts the stick range from the quasi-static pitch response (alpha per unit
/// elevator and g per unit alpha at the current dynamic pressure), which is stable because it contains
/// no feedback loop. A small proportional term trims any residual excess.
public struct FlightControlLaw: Sendable, Equatable {
    public var limits: EnvelopeLimits
    public var config: AircraftConfig
    /// Fraction of the g limit the feed-forward allows, leaving room for pitch-damping overshoot.
    public var margin = 0.95
    public var residualGain = 0.05

    public init(limits: EnvelopeLimits, config: AircraftConfig) {
        self.limits = limits; self.config = config
    }

    /// Stick range (min, max) permitted at dynamic pressure `qbar` (Pa).
    public func elevatorRange(qbar: Double) -> (min: Double, max: Double) {
        let a = config.aero
        let alphaPerStick = abs(a.cmElevator) * config.elevatorMax / max(1e-6, abs(a.cmAlpha))
        let gPerStick = qbar * config.wingArea * a.cLAlpha * alphaPerStick / (config.mass * ISA.g0)
        guard gPerStick > 1e-6 else { return (-1, 1) }
        let hiG = (limits.nzMax * margin - 1) / gPerStick
        let loG = (limits.nzMin * margin - 1) / gPerStick
        let hiAlpha = limits.alphaLimit / alphaPerStick
        return (max(-1, loG), min(1, hiG, hiAlpha))
    }

    public func apply(_ pilot: ControlInputs, qbar: Double, nz: Double) -> ControlInputs {
        var out = pilot.sanitized
        let range = elevatorRange(qbar: qbar)
        var e = min(range.max, max(range.min, out.elevator))
        if nz > limits.nzMax { e -= residualGain * (nz - limits.nzMax) }
        if nz < limits.nzMin { e += residualGain * (limits.nzMin - nz) }
        out.elevator = min(1, max(-1, e))
        return out
    }
}

public enum EnvelopeWarning: String, Sendable, Codable, CaseIterable, Comparable {
    case stall, overspeed, overMach, flapOverspeed, overG, negativeG, terrain

    public static func < (a: EnvelopeWarning, b: EnvelopeWarning) -> Bool { a.rawValue < b.rawValue }
}

/// Raises warnings and tracks overstress. An airframe fails when it stays past 150 % of a g limit (in the
/// air) or 125 % of never-exceed speed for a quarter of a second.
public struct EnvelopeMonitor: Sendable {
    public let limits: EnvelopeLimits
    public private(set) var warnings: Set<EnvelopeWarning> = []
    public private(set) var peakG = 1.0
    public private(set) var minG = 1.0
    public private(set) var peakMach = 0.0
    /// Seconds spent beyond the g or speed limits (feeds the mission score).
    public private(set) var overstressSeconds = 0.0
    public private(set) var structuralFailure = false
    /// How long the airframe has been past the failure threshold (s). A hard but legal touchdown spikes
    /// the gear load for a few steps, so failure needs `failureHold` seconds and g is ignored on the ground.
    private var failureTime = 0.0
    public static let failureHold = 0.25

    public init(limits: EnvelopeLimits) { self.limits = limits }

    public mutating func update(nz: Double, trueAirspeed v: Double, mach: Double, flaps: Double,
                                stalled: Bool, onGround: Bool, heightAGL: Double, sinkRate: Double, dt: Double) {
        var w: Set<EnvelopeWarning> = []
        if stalled && !onGround { w.insert(.stall) }
        if v > limits.vne { w.insert(.overspeed) }
        if mach > limits.mmo { w.insert(.overMach) }
        if flaps > 0.05 && v > limits.vfe { w.insert(.flapOverspeed) }
        if nz > limits.nzMax { w.insert(.overG) }
        if nz < limits.nzMin { w.insert(.negativeG) }
        // Terrain: under 8 s to impact at the present sink rate and low.
        if !onGround && heightAGL < 450 && sinkRate > 2 && heightAGL / sinkRate < 8 { w.insert(.terrain) }
        warnings = w
        peakG = max(peakG, nz); minG = min(minG, nz); peakMach = max(peakMach, mach)
        if w.contains(.overG) || w.contains(.negativeG) || w.contains(.overspeed) || w.contains(.overMach) {
            overstressSeconds += dt
        }
        let overG = !onGround && (nz > limits.nzMax * 1.5 || nz < limits.nzMin * 1.5)
        if overG || v > limits.vne * 1.25 { failureTime += dt } else { failureTime = 0 }
        if failureTime >= Self.failureHold { structuralFailure = true }
    }
}
