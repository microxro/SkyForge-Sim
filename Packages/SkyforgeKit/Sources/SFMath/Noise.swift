// SKYFORGE — Apache-2.0
import Foundation
/// Deterministic gradient (Perlin-style) noise and fBm, written from scratch (no LGPL libnoise).
public struct GradientNoise2D: Sendable {
    public let seed: UInt64
    public init(seed: UInt64) { self.seed = seed }

    @inline(__always) func grad(_ ix: Int, _ iy: Int, _ dx: Double, _ dy: Double) -> Double {
        let h = Hash.int(ix, iy, seed: seed)
        let a = Hash.unit(h) * 2 * .pi
        return cos(a) * dx + sin(a) * dy
    }
    @inline(__always) static func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }

    /// Returns approximately [-1, 1].
    public func sample(_ x: Double, _ y: Double) -> Double {
        let x0 = Int((x).rounded(.down)), y0 = Int((y).rounded(.down))
        let fx = x - Double(x0), fy = y - Double(y0)
        let u = Self.fade(fx), v = Self.fade(fy)
        let n00 = grad(x0, y0, fx, fy)
        let n10 = grad(x0 + 1, y0, fx - 1, fy)
        let n01 = grad(x0, y0 + 1, fx, fy - 1)
        let n11 = grad(x0 + 1, y0 + 1, fx - 1, fy - 1)
        let nx0 = n00 + u * (n10 - n00)
        let nx1 = n01 + u * (n11 - n01)
        return (nx0 + v * (nx1 - nx0)) * 1.4142
    }

    /// Fractional Brownian motion.
    public func fbm(_ x: Double, _ y: Double, octaves: Int = 5, lacunarity: Double = 2.0, gain: Double = 0.5) -> Double {
        var sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0
        for o in 0..<octaves {
            let off = Double(o) * 17.13
            sum += amp * sample(x * freq + off, y * freq - off)
            norm += amp
            amp *= gain; freq *= lacunarity
        }
        return sum / norm
    }

    /// Ridged multifractal, roughly [0, 1], good for mountain ridges.
    public func ridged(_ x: Double, _ y: Double, octaves: Int = 5) -> Double {
        var sum = 0.0, amp = 0.5, freq = 1.0, weight = 1.0
        for o in 0..<octaves {
            let off = Double(o) * 31.7
            var n = 1.0 - abs(sample(x * freq + off, y * freq + off))
            n *= n
            n *= weight
            weight = min(1, max(0, n * 2))
            sum += n * amp
            amp *= 0.5; freq *= 2.0
        }
        return min(1, sum * 1.1)
    }
}

@inlinable public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inlinable public func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
@inlinable public func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clamp((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}
