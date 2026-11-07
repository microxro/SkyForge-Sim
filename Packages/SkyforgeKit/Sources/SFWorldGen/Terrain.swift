// SKYFORGE — Apache-2.0
// Procedural terrain "recipes" for test regions. In P1 these stand in for the real DEM skeleton
// (P1.2b); every recipe is a pure function of (seed, x, y) in local metres (x east, y north, z up).
import Foundation
import SFMath

public enum TerrainKind: String, Sendable, CaseIterable, Codable {
    case suburbanPlain, forestRiver, coastline, mountainValley
}

/// A river described by a centre-line polyline with a width (metres).
public struct River: Sendable, Equatable {
    public var points: [SIMD2<Double>]
    public var width: Double
}

public struct TerrainRecipe: Sendable {
    public let kind: TerrainKind
    public let seed: UInt64
    let noise: GradientNoise2D
    let detail: GradientNoise2D
    public let seaLevel: Double
    public let river: River?
    /// Flattened rectangles (airports): centre, half-length along heading, half-width, heading (rad from north), elevation.
    public var flattenZones: [(centre: SIMD2<Double>, halfLength: Double, halfWidth: Double, heading: Double, elevation: Double)] = []

    public init(kind: TerrainKind, seed: UInt64) {
        self.kind = kind
        self.seed = seed
        noise = GradientNoise2D(seed: Hash.combine(seed, 0x7E44))
        detail = GradientNoise2D(seed: Hash.combine(seed, 0xDE7A))
        switch kind {
        case .coastline: seaLevel = 0
        default: seaLevel = -1_000
        }
        if kind == .forestRiver || kind == .mountainValley {
            // Meandering river roughly south -> north through the origin.
            var rng = Xoshiro256(seed: Hash.combine(seed, 0x81E))
            var pts: [SIMD2<Double>] = []
            let phase = rng.range(0, 6.28)
            let amp = kind == .forestRiver ? 260.0 : 90.0
            for i in 0...640 {
                let y = -24_000 + Double(i) * 75
                let x = amp * sin(y / 900 + phase) + 0.45 * amp * sin(y / 370 + phase * 2.3) - 150
                pts.append(SIMD2(x, y))
            }
            river = River(points: pts, width: kind == .forestRiver ? 55 : 28)
        } else {
            river = nil
        }
    }

    /// Distance (m) from a point to the river centre-line, or +inf without a river.
    public func riverDistance(_ x: Double, _ y: Double) -> Double {
        guard let r = river else { return .infinity }
        // Points are uniformly spaced in y; search a small window.
        let last = r.points.count - 2
        let idx = Int(((y - r.points[0].y) / 75).rounded())
        let lo = min(max(idx - 3, 0), last), hi = min(max(idx + 3, 0), last)
        var best = Double.infinity
        for i in lo...hi {
            let a = r.points[i], b = r.points[i + 1]
            let ab = b - a, ap = SIMD2(x, y) - a
            let t = clamp((ap * ab).sum() / (ab * ab).sum(), 0, 1)
            let d = ap - ab * t
            best = min(best, (d * d).sum().squareRoot())
        }
        return best
    }

    /// Ground elevation (m), including flattened airport zones blended over a 150 m embankment.
    public func height(_ x: Double, _ y: Double) -> Double {
        let natural = naturalHeight(x, y)
        guard !flattenZones.isEmpty else { return natural }
        var h = natural
        for z in flattenZones {
            let d = SIMD2(x, y) - z.centre
            let a = SIMD2(sin(z.heading), cos(z.heading))
            let la = abs((d * a).sum()), lc = abs(d.x * a.y - d.y * a.x)
            let outside = max(la - z.halfLength, lc - z.halfWidth, 0)
            let w = 1 - smoothstep(0, 150, outside)
            h = h + (z.elevation - h) * w
        }
        return h
    }

    func naturalHeight(_ x: Double, _ y: Double) -> Double {
        let fine = detail.fbm(x / 140, y / 140, octaves: 3) * 1.2
        switch kind {
        case .suburbanPlain:
            let rolling = noise.fbm(x / 2_600, y / 2_600, octaves: 4) * 22
            return 40 + rolling + fine
        case .forestRiver:
            let hills = noise.fbm(x / 1_800, y / 1_800, octaves: 5) * 90 + 120
            let d = riverDistance(x, y)
            let valley = smoothstep(0, 700, d)
            let bed = 60.0
            let channel = river.map { d < $0.width / 2 + 4 ? -4.0 * (1 - d / ($0.width / 2 + 4)) - 2.5 : 0 } ?? 0
            return lerp(bed, hills, valley) + fine * valley + channel
        case .coastline:
            // Land rises inland (to the west); a noisy coastline runs north-south near x = 600.
            let coast = 600 + noise.fbm(y / 1_500, 3.3, octaves: 4) * 500
            let inland = (coast - x) / 1_000
            let base = inland > 0 ? 6 + inland * 55 + noise.fbm(x / 900, y / 900, octaves: 4) * 25 * min(1, inland)
                                  : inland * 40
            let cliffs = inland > 0 ? smoothstep(0, 0.08, inland) * 18 : 0
            return base + cliffs + fine
        case .mountainValley:
            let d = riverDistance(x, y)
            let channel = d < 24 ? 3.5 * (1 - d / 24) + 1.5 : 0
            let bankFade = smoothstep(10, 60, d)   // keep micro-detail out of the river channel
            return mountainBase(x, y) - channel + fine * 2 * bankFade
        }
    }

    /// Mountain valley surface without the river channel.
    func mountainBase(_ x: Double, _ y: Double) -> Double {
        let ridge = noise.ridged(x / 4_500, y / 4_500, octaves: 6)
        let valleyShape = smoothstep(300, 2_400, abs(x + 150 - 90 * sin(y / 900)))
        let mountains = 690 + ridge * 2_000 * valleyShape + valleyShape * 500
        let floor = 680 + noise.fbm(x / 1_200, y / 1_200, octaves: 3) * 15
        return max(floor, mountains)
    }

    /// Whether a point lies on (or within `margin` of) a flattened airport zone.
    public func isAirport(_ x: Double, _ y: Double, margin: Double = 60) -> Bool {
        for z in flattenZones {
            let d = SIMD2(x, y) - z.centre
            let a = SIMD2(sin(z.heading), cos(z.heading))
            if abs((d * a).sum()) < z.halfLength + margin && abs(d.x * a.y - d.y * a.x) < z.halfWidth + margin { return true }
        }
        return false
    }

    /// Surface normal from central differences.
    public func normal(_ x: Double, _ y: Double, step: Double = 4) -> SIMD3<Double> {
        let hx = height(x + step, y) - height(x - step, y)
        let hy = height(x, y + step) - height(x, y - step)
        return normalize(SIMD3(-hx / (2 * step), -hy / (2 * step), 1))
    }

    /// Whether a point is open water (sea or river).
    public func isWater(_ x: Double, _ y: Double) -> Bool {
        if height(x, y) < seaLevel { return true }
        if let r = river, riverDistance(x, y) < r.width / 2 { return true }
        return false
    }

    /// Water surface height at a point (sea level or river surface).
    public func waterHeight(_ x: Double, _ y: Double) -> Double {
        if kind == .coastline { return seaLevel }
        switch kind {
        case .forestRiver: return 58
        case .mountainValley: return mountainBase(x, y) - 2
        default: return seaLevel
        }
    }
}
