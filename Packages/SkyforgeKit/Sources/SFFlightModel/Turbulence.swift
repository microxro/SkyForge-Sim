// SKYFORGE — Apache-2.0
// Seeded, deterministic atmospheric turbulence after the Dryden spectra of MIL-HDBK-1797, using
// first-order (Ornstein-Uhlenbeck) shaping filters for all three axes (the exact Dryden w-axis is
// second order; the first-order form matches its low-frequency energy and is cheap at 120 Hz).
// Output is a NED gust vector the orchestrator adds to FlightEnvironment.windNED.
import Foundation
import SFMath

public struct DrydenTurbulence: Sendable {
    public enum Severity: Double, Sendable, CaseIterable {
        case none = 0, light = 0.9, moderate = 2.1, severe = 4.0   // sigma (m/s) above 600 m AGL
    }

    private var rng: Xoshiro256
    private var u = 0.0, v = 0.0, w = 0.0
    public var severity: Severity
    /// Mean wind at 6 m (20 ft) AGL in m/s, which sets the low-altitude intensity (sigma_w = 0.1 W20).
    public var wind20: Double

    public init(seed: UInt64, severity: Severity = .light, wind20: Double = 5) {
        rng = Xoshiro256(seed: seed); self.severity = severity; self.wind20 = wind20
    }

    private mutating func gauss() -> Double {
        let u1 = max(rng.unit(), 1e-12), u2 = rng.unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    /// Dryden scale length (m) and sigma (m/s) for the vertical and horizontal axes at a height above ground.
    static func scales(heightAGL h: Double, severity: Severity, wind20: Double) -> (lw: Double, lh: Double, sw: Double, sh: Double) {
        let hm = max(h, 3)
        let hFt = hm / 0.3048
        let low = 0.177 + 0.000823 * hFt
        if hFt < 1_000 {
            let lh = hm / pow(low, 1.2)
            let sw = 0.1 * wind20 * (severity == .none ? 0 : 1)
            let sh = sw / pow(low, 0.4)
            return (hm, lh, sw, sh)
        }
        let sigma = severity.rawValue
        let l = 533.0   // 1750 ft
        // Blend the low-altitude sigma into the mid-altitude value between 1,000 and 2,000 ft.
        let sw0 = 0.1 * wind20 * (severity == .none ? 0 : 1)
        let t = min(1, (hFt - 1_000) / 1_000)
        let sw = sw0 + (sigma - sw0) * t
        return (l, l, sw, sw)
    }

    /// Advances one step and returns the NED gust (m/s). `headingRad` aligns the longitudinal gust with the
    /// aircraft's ground track.
    public mutating func step(dt: Double, heightAGL: Double, airspeed: Double, headingRad: Double) -> SIMD3<Double> {
        guard severity != .none, dt.isFinite, dt > 0 else { return .zero }
        let sc = Self.scales(heightAGL: heightAGL, severity: severity, wind20: wind20)
        let va = airspeed.isFinite ? max(airspeed, 5) : 5
        func advance(_ x: Double, _ length: Double, _ sigma: Double) -> Double {
            let a = exp(-va * dt / max(length, 1))
            return a * x + sigma * (1 - a * a).squareRoot() * gauss()
        }
        u = advance(u, sc.lh, sc.sh)
        v = advance(v, sc.lh, sc.sh)
        w = advance(w, sc.lw, sc.sw)
        let ch = cos(headingRad), sh = sin(headingRad)
        return SIMD3(u * ch - v * sh, u * sh + v * ch, w)
    }
}
