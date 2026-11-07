// SKYFORGE — Apache-2.0
// US Standard Atmosphere 1976 (identical to ICAO ISA below 32 km), geopotential layers to 86 km.
import Foundation
import SFMath

public struct AtmosphereState: Sendable, Equatable {
    /// Static temperature (K)
    public var temperature: Double
    /// Static pressure (Pa)
    public var pressure: Double
    /// Density (kg/m^3)
    public var density: Double
    /// Speed of sound (m/s)
    public var speedOfSound: Double
    /// Dynamic viscosity (Pa*s), Sutherland's law
    public var viscosity: Double
}

public enum ISA {
    public static let r: Double = 287.052_87       // J/(kg K), specific gas constant for dry air
    public static let gamma: Double = 1.4
    public static let g0: Double = 9.806_65
    public static let earthRadius: Double = 6_356_766  // m, USSA-76 geopotential radius
    public static let seaLevelTemperature: Double = 288.15
    public static let seaLevelPressure: Double = 101_325
    public static let seaLevelDensity: Double = 1.225

    /// (base geopotential altitude m, lapse rate K/m)
    static let layers: [(h: Double, lapse: Double)] = [
        (0, -0.0065), (11_000, 0), (20_000, 0.001), (32_000, 0.0028),
        (47_000, 0), (51_000, -0.0028), (71_000, -0.002), (84_852, 0),
    ]
    /// Base temperatures and pressures, computed once.
    static let bases: [(t: Double, p: Double)] = {
        var out: [(Double, Double)] = []
        var t = seaLevelTemperature, p = seaLevelPressure
        for i in 0..<layers.count {
            out.append((t, p))
            guard i + 1 < layers.count else { break }
            let dh = layers[i + 1].h - layers[i].h
            let lapse = layers[i].lapse
            let tNext = t + lapse * dh
            if lapse == 0 {
                p *= exp(-g0 * dh / (r * t))
            } else {
                p *= pow(tNext / t, -g0 / (lapse * r))
            }
            t = tNext
        }
        return out
    }()

    public static func geopotential(fromGeometric z: Double) -> Double { earthRadius * z / (earthRadius + z) }

    /// Standard atmosphere at a geometric altitude (m). Clamped to [-5 km, 86 km].
    public static func state(geometricAltitude z: Double, temperatureOffset dT: Double = 0) -> AtmosphereState {
        let h = clamp(geopotential(fromGeometric: z), -5_000, 84_852)
        var i = layers.count - 1
        while i > 0 && h < layers[i].h { i -= 1 }
        let base = bases[i], lapse = layers[i].lapse, dh = h - layers[i].h
        let tStd = base.t + lapse * dh
        let p: Double = lapse == 0
            ? base.p * exp(-g0 * dh / (r * base.t))
            : base.p * pow(tStd / base.t, -g0 / (lapse * r))
        let t = tStd + dT
        let rho = p / (r * t)
        return AtmosphereState(
            temperature: t, pressure: p, density: rho,
            speedOfSound: (gamma * r * t).squareRoot(),
            viscosity: 1.458e-6 * pow(t, 1.5) / (t + 110.4)
        )
    }

    /// Pressure altitude (m) for a static pressure (Pa) in the troposphere/lower stratosphere.
    public static func pressureAltitude(pressure p: Double) -> Double {
        if p >= bases[1].p {
            return (seaLevelTemperature / 0.0065) * (1 - pow(p / seaLevelPressure, 0.0065 * r / g0))
        }
        return 11_000 + (r * bases[1].t / g0) * log(bases[1].p / p)
    }

    /// Density altitude (m) for a density (kg/m^3), troposphere approximation.
    public static func densityAltitude(density rho: Double) -> Double {
        (seaLevelTemperature / 0.0065) * (1 - pow(rho / seaLevelDensity, 1 / (g0 / (0.0065 * r) - 1)))
    }

    /// Indicated altitude (m) for an altimeter set to QNH (Pa) at true static pressure p.
    public static func indicatedAltitude(staticPressure p: Double, qnh: Double) -> Double {
        pressureAltitude(pressure: p) - pressureAltitude(pressure: qnh)
    }
}

/// Airspeed conversions with compressible pitot theory (subsonic).
public enum Airspeed {
    static let a0 = (ISA.gamma * ISA.r * ISA.seaLevelTemperature).squareRoot()

    /// Impact pressure (Pa) from Mach and static pressure.
    public static func impactPressure(mach: Double, staticPressure p: Double) -> Double {
        p * (pow(1 + 0.2 * mach * mach, 3.5) - 1)
    }

    public static func calibratedAirspeed(trueAirspeed tas: Double, atmosphere s: AtmosphereState) -> Double {
        let mach = tas / s.speedOfSound
        let qc = impactPressure(mach: mach, staticPressure: s.pressure)
        return a0 * (5 * (pow(qc / ISA.seaLevelPressure + 1, 2.0 / 7.0) - 1)).squareRoot()
    }

    public static func trueAirspeed(calibratedAirspeed cas: Double, atmosphere s: AtmosphereState) -> Double {
        let qc = ISA.seaLevelPressure * (pow(1 + 0.2 * (cas / a0) * (cas / a0), 3.5) - 1)
        let mach = (5 * (pow(qc / s.pressure + 1, 2.0 / 7.0) - 1)).squareRoot()
        return mach * s.speedOfSound
    }

    public static func equivalentAirspeed(trueAirspeed tas: Double, atmosphere s: AtmosphereState) -> Double {
        tas * (s.density / ISA.seaLevelDensity).squareRoot()
    }
}
