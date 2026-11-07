// SKYFORGE — Apache-2.0
// Procedural app icon: golden-hour sky, sun, layered ridges and a stylised aircraft silhouette.
import Foundation

public enum IconRenderer {
    /// Returns RGB8 pixels for a square icon of `size` pixels (4x4 supersampled).
    public static func render(size: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size * size * 3)
        let ss = 4
        for py in 0..<size {
            for px in 0..<size {
                var acc = SIMD3<Double>(0, 0, 0)
                for sy in 0..<ss {
                    for sx in 0..<ss {
                        let u = (Double(px) + (Double(sx) + 0.5) / Double(ss)) / Double(size)
                        let v = (Double(py) + (Double(sy) + 0.5) / Double(ss)) / Double(size)
                        acc += shade(u, v)
                    }
                }
                acc /= Double(ss * ss)
                let i = (py * size + px) * 3
                out[i] = UInt8(max(0, min(255, (pow(acc.x, 1 / 2.2) * 255).rounded())))
                out[i + 1] = UInt8(max(0, min(255, (pow(acc.y, 1 / 2.2) * 255).rounded())))
                out[i + 2] = UInt8(max(0, min(255, (pow(acc.z, 1 / 2.2) * 255).rounded())))
            }
        }
        return out
    }

    static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { a + (b - a) * max(0, min(1, t)) }

    /// u,v in [0,1], v down. Linear-light colour.
    static func shade(_ u: Double, _ v: Double) -> SIMD3<Double> {
        let zenith = SIMD3<Double>(0.05, 0.11, 0.30)
        let horizon = SIMD3<Double>(1.00, 0.52, 0.22)
        var c = mix(zenith, horizon, pow(v / 0.70, 1.6))
        // Sun disc and glow
        let sun = SIMD2<Double>(0.66, 0.60)
        let d = ((u - sun.x) * (u - sun.x) + (v - sun.y) * (v - sun.y)).squareRoot()
        c += SIMD3<Double>(1.0, 0.75, 0.40) * (0.55 * exp(-d * 7))
        if d < 0.085 { c = mix(c, SIMD3<Double>(1.0, 0.93, 0.75), 1) }
        // Layered ridges (aerial perspective: farther ridges lighter)
        let ridges: [(base: Double, amp: Double, freq: Double, phase: Double, col: SIMD3<Double>)] = [
            (0.70, 0.050, 9.0, 0.3, SIMD3<Double>(0.55, 0.30, 0.22)),
            (0.76, 0.060, 6.5, 1.7, SIMD3<Double>(0.28, 0.14, 0.13)),
            (0.84, 0.050, 4.5, 2.9, SIMD3<Double>(0.10, 0.06, 0.08)),
        ]
        for r in ridges {
            let h = r.base - r.amp * (0.6 * sin(u * r.freq + r.phase) + 0.4 * sin(u * r.freq * 2.3 + r.phase * 1.7))
            if v > h { c = r.col }
        }
        // Aircraft silhouette, banked, upper left
        let cx = 0.38, cy = 0.36, ang = -0.30
        let x = (u - cx) * cos(ang) - (v - cy) * sin(ang)
        let y = (u - cx) * sin(ang) + (v - cy) * cos(ang)
        let silhouette = SIMD3<Double>(0.03, 0.03, 0.06)
        let fuselage = abs(y) < 0.022 * (1 - min(1, max(0, (x - 0.10) / 0.18))) + 0.004 && x > -0.20 && x < 0.26
        let wing = abs(x - 0.02 + abs(y) * 0.18) < 0.035 && abs(y) < 0.24
        let tail = abs(x + 0.17 + abs(y) * 0.15) < 0.022 && abs(y) < 0.085
        if fuselage || wing || tail { c = silhouette }
        return c
    }
}
