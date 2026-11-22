// SKYFORGE — Apache-2.0
// Propulsion models for the flight model: piston/propeller (Gagg-Farrar altitude lapse, optional
// turbocharger critical altitude, prop torque and P-factor) and turbojet/turbofan with optional
// afterburner (empirical density and Mach lapse). Multi-engine layouts with per-engine failures.
// Thrust coefficients are engineering-estimate values from public-domain textbook methods, not data
// from any real engine.
import Foundation
import SFMath
import SFAtmosphere

public struct PropulsionConfig: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case piston, turbojet }

    public var kind: Kind
    /// Number of engines (1, 2 or 4). Engine 0 is the right-most, engine 1 the left-most, then pairs outward.
    public var engineCount: Int
    /// Lateral distance (m) of the innermost off-centre engine from the centreline.
    public var engineSpanOffset: Double

    // Piston / propeller
    public var powerPerEngine: Double = 0            // W at sea level
    public var staticThrustPerWatt: Double = 0.02    // N/W standstill
    public var propEfficiency: Double = 0.80
    public var maxRPM: Double = 2_700
    /// Turbocharger critical altitude (m). 0 = naturally aspirated.
    public var criticalAltitude: Double = 0
    /// Fraction of shaft torque reacted as a roll moment (left roll for a clockwise propeller).
    public var propTorqueRoll: Double = 0
    /// P-factor arm (m): yaw moment = -thrust * arm * alpha (left-turning tendency).
    public var pFactorArm: Double = 0

    // Jet
    public var dryThrust: Double = 0                 // N per engine, sea-level static, military power
    public var afterburnerThrust: Double = 0         // N per engine, sea-level static; 0 = no afterburner
    /// Idle thrust as a fraction of dry thrust.
    public var idleFraction: Double = 0.04

    /// Windmilling drag area (m^2) of a failed, unfeathered engine.
    public var windmillDragArea: Double = 0.4

    public init(kind: Kind, engineCount: Int, engineSpanOffset: Double = 0) {
        self.kind = kind; self.engineCount = engineCount; self.engineSpanOffset = engineSpanOffset
    }

    /// Lateral (y, right positive) position of engine `i` in metres from the centreline.
    public func enginePosition(_ i: Int) -> Double {
        guard engineCount > 1 else { return 0 }
        let side: Double = i % 2 == 0 ? 1 : -1
        return side * engineSpanOffset * Double(i / 2 + 1)
    }

    public var hasAfterburner: Bool { kind == .turbojet && afterburnerThrust > dryThrust }

    /// Per-engine thrust (N) and shaft power (W, 0 for jets).
    /// - Parameters:
    ///   - throttle: 0…1. For afterburning jets 0…0.8 is dry power and 0.8…1 is afterburner.
    ///   - altitude: geometric altitude (m) used for the turbocharger critical altitude.
    ///   - axialSpeed: airspeed along the thrust line (m/s).
    public func engineOutput(throttle: Double, density: Double, altitude: Double, mach: Double, axialSpeed: Double) -> (thrust: Double, shaftPower: Double) {
        let sigma = density / ISA.seaLevelDensity
        switch kind {
        case .piston:
            var ratio: Double
            if criticalAltitude > 0 {
                let sigmaCrit = ISA.state(geometricAltitude: criticalAltitude).density / ISA.seaLevelDensity
                ratio = sigma >= sigmaCrit ? 1 : max(0, 1.132 * (sigma / sigmaCrit) - 0.132)
            } else {
                ratio = max(0, 1.132 * sigma - 0.132)
            }
            ratio = min(ratio, 1)
            let power = powerPerEngine * throttle * ratio
            guard power > 0 else { return (0, 0) }
            let v0 = propEfficiency / max(staticThrustPerWatt, 1e-6)
            let vx = max(0, axialSpeed)
            return (propEfficiency * power / (vx * vx + v0 * v0).squareRoot(), power)
        case .turbojet:
            let m = min(max(mach, 0), 3)
            let mil = hasAfterburner ? min(throttle / 0.8, 1) : throttle
            let dryFrac = idleFraction + (1 - idleFraction) * mil
            let dryMach = 1 - 0.10 * m + 0.20 * m * m
            var thrust = dryThrust * dryFrac * pow(sigma, 0.75) * dryMach
            if hasAfterburner && throttle > 0.8 {
                let abFrac = (throttle - 0.8) / 0.2
                let abMach = 1 + 0.60 * m - 0.05 * m * m
                thrust += (afterburnerThrust - dryThrust) * abFrac * pow(sigma, 0.85) * abMach
            }
            return (max(0, thrust), 0)
        }
    }
}

/// First-order engine response (jets spool slowly, pistons almost instantly). Pure value type: the
/// orchestrator keeps one per engine and feeds its output to `ControlInputs.throttle`.
public struct EngineSpool: Sendable, Equatable {
    public var level: Double
    public var spoolUpTime: Double       // s (time constant)
    public var spoolDownTime: Double     // s
    public init(level: Double = 0, spoolUpTime: Double = 0.4, spoolDownTime: Double = 0.3) {
        self.level = level; self.spoolUpTime = spoolUpTime; self.spoolDownTime = spoolDownTime
    }
    public static let piston = EngineSpool(level: 0, spoolUpTime: 0.35, spoolDownTime: 0.25)
    public static let jet = EngineSpool(level: 0, spoolUpTime: 2.2, spoolDownTime: 1.2)

    /// Advances toward `command` (0…1). Jets accelerate more slowly at low RPM (`1 + 2(1-level)` factor).
    @discardableResult
    public mutating func update(command: Double, dt: Double, slowAtLowRPM: Bool = false) -> Double {
        guard dt.isFinite, dt > 0 else { return level }
        let cmd = command.isFinite ? min(1, max(0, command)) : 0
        var tau = cmd > level ? spoolUpTime : spoolDownTime
        if slowAtLowRPM && cmd > level { tau *= 1 + 2 * (1 - level) }
        let k = 1 - exp(-dt / max(tau, 1e-4))
        level += (cmd - level) * k
        return level
    }
}
