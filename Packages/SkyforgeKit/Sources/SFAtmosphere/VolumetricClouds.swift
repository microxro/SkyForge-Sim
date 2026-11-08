// SKYFORGE — Apache-2.0
// Volumetric cumulus: the CPU reference for the Metal cloud pass (CloudShaders.swift mirrors this
// file operation for operation, in Float, so GPU output can be checked against it in CI).
//
// Model (after Schneider 2015 "The real-time volumetric cloudscapes of Horizon: Zero Dawn" and
// Hillaire 2016 "Physically based sky, atmosphere and cloud rendering in Frostbite"):
// - a slab between `base` and `base + thickness` (metres AMSL, z up, local ENU metres);
// - 2D coverage noise (2.6 km + 0.9 km cells) thresholded by `coverage`, tapered with height so
//   cells grow flat bases and rounded tops; 3D value-noise erosion (220 m + 90 m) for billows;
// - energy-conserving integration of single scattering with a dual-lobe Henyey–Greenstein phase,
//   a cheap multiple-scattering term (Beer at reduced extinction) and height-dependent sky ambient.
import Foundation

/// One cumulus layer.
public struct CloudLayer: Sendable, Equatable {
    public var base: Float          // metres AMSL
    public var thickness: Float     // metres
    public var coverage: Float      // 0 (clear) … 1 (overcast)
    public var extinction: Float    // 1/m at full density (cumulus ≈ 0.03–0.1)
    public var offset: SIMD2<Float> // wind drift (metres east, north)

    public init(base: Float = 1_400, thickness: Float = 1_300, coverage: Float = 0.42, extinction: Float = 0.045,
                offset: SIMD2<Float> = .zero) {
        self.base = base; self.thickness = thickness; self.coverage = coverage; self.extinction = extinction; self.offset = offset
    }

    public static let fairWeather = CloudLayer()
    public static let clear = CloudLayer(coverage: 0)

    public var top: Float { base + thickness }
}

/// Result of marching one view ray through the layer.
public struct CloudSample: Sendable, Equatable {
    public var radiance: SIMD3<Float>   // in-scattered light reaching the eye (renderer units)
    public var transmittance: Float     // fraction of the background that remains visible
    public var depth: Float             // transmittance-weighted mean distance of the cloud (m), 0 if none
    public init(radiance: SIMD3<Float>, transmittance: Float, depth: Float) {
        self.radiance = radiance; self.transmittance = transmittance; self.depth = depth
    }
}

public enum VolumetricClouds {
    public static let maxMarchDistance: Float = 24_000
    public static let lightSteps = 6

    // MARK: Noise (integer hash so Swift and MSL agree bit for bit on the lattice values)

    @inline(__always) static func hash(_ x: Int32, _ y: Int32, _ z: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 0x8DA6_B343
        h ^= UInt32(bitPattern: y) &* 0xD816_3841
        h ^= UInt32(bitPattern: z) &* 0xCB1A_B31F
        h ^= h >> 13
        h = h &* 0x5BD1_E995
        h ^= h >> 15
        return Float(h & 0x00FF_FFFF) / 16_777_216
    }

    @inline(__always) static func fade(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    /// Trilinear value noise in [0, 1).
    public static func noise(_ p: SIMD3<Float>) -> Float {
        let fx = p.x.rounded(.down), fy = p.y.rounded(.down), fz = p.z.rounded(.down)
        let ix = Int32(fx), iy = Int32(fy), iz = Int32(fz)
        let tx = fade(p.x - fx), ty = fade(p.y - fy), tz = fade(p.z - fz)
        func l(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
        let c000 = hash(ix, iy, iz), c100 = hash(ix + 1, iy, iz)
        let c010 = hash(ix, iy + 1, iz), c110 = hash(ix + 1, iy + 1, iz)
        let c001 = hash(ix, iy, iz + 1), c101 = hash(ix + 1, iy, iz + 1)
        let c011 = hash(ix, iy + 1, iz + 1), c111 = hash(ix + 1, iy + 1, iz + 1)
        return l(l(l(c000, c100, tx), l(c010, c110, tx), ty), l(l(c001, c101, tx), l(c011, c111, tx), ty), tz)
    }

    @inline(__always) static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Density

    /// Extinction coefficient (1/m) at local position `p`.
    public static func density(_ p: SIMD3<Float>, _ c: CloudLayer) -> Float {
        let h = (p.z - c.base) / c.thickness
        if h <= 0 || h >= 1 || c.coverage <= 0 { return 0 }
        let qx = p.x + c.offset.x, qy = p.y + c.offset.y
        let cov = 0.65 * noise(SIMD3(qx / 2_600, qy / 2_600, 0.5)) + 0.35 * noise(SIMD3(qx / 900, qy / 900, 17.5))
        var s = (cov - (1 - c.coverage)) / max(c.coverage, 0.05)
        s = s * smoothstep(0, 0.12, h) - 0.55 * h * h
        if s <= 0 { return 0 }
        let detail = 0.625 * noise(SIMD3(qx, qy, p.z) / 220) + 0.375 * noise(SIMD3(qx, qy, p.z * 1.3) / 90)
        let d = s - (1 - detail) * 0.22
        if d <= 0 { return 0 }
        return min(1, d * 2.2) * c.extinction
    }

    // MARK: Lighting

    @inline(__always) static func hg(_ cosT: Float, _ g: Float) -> Float {
        let g2 = g * g
        let denom = max(1e-4, 1 + g2 - 2 * g * cosT)
        return (1 - g2) / (4 * Float.pi * denom * denom.squareRoot())
    }

    /// Dual-lobe phase (forward silver lining + soft back scatter), normalised over the sphere.
    public static func phase(_ cosT: Float) -> Float { 0.7 * hg(cosT, 0.6) + 0.3 * hg(cosT, -0.25) }

    /// Optical depth toward the sun from `p` (6 steps of doubling length, 40 m → 1.3 km).
    static func lightDepth(_ p: SIMD3<Float>, _ toSun: SIMD3<Float>, _ c: CloudLayer) -> Float {
        var od: Float = 0, t: Float = 0, step: Float = 40
        for _ in 0..<lightSteps {
            let q = p + toSun * (t + 0.5 * step)
            od += density(q, c) * step
            t += step; step *= 1.8
        }
        return od
    }

    /// Ray-slab interval [t0, t1] clipped to [0, min(maxDist, maxMarchDistance)], or nil.
    public static func interval(origin o: SIMD3<Float>, dir d: SIMD3<Float>, maxDist: Float, _ c: CloudLayer) -> (Float, Float)? {
        var t0: Float = 0, t1 = min(maxDist, maxMarchDistance)
        if abs(d.z) < 1e-5 {
            if o.z <= c.base || o.z >= c.top { return nil }
        } else {
            let ta = (c.base - o.z) / d.z, tb = (c.top - o.z) / d.z
            t0 = max(t0, min(ta, tb)); t1 = min(t1, max(ta, tb))
        }
        return t1 > t0 ? (t0, t1) : nil
    }

    /// Marches one ray. `sun` is the sun colour (renderer units: a white Lambertian surface facing the
    /// sun has radiance `sun`), `skyAmbient` the sky irradiance term, `jitter` in [0, 1) offsets samples.
    public static func march(origin o: SIMD3<Float>, dir d: SIMD3<Float>, maxDist: Float, layer c: CloudLayer,
                             toSun: SIMD3<Float>, sun: SIMD3<Float>, skyAmbient: SIMD3<Float>, groundAmbient: SIMD3<Float>,
                             steps: Int, jitter: Float) -> CloudSample {
        guard c.coverage > 0, let (t0, t1) = interval(origin: o, dir: d, maxDist: maxDist, c) else {
            return CloudSample(radiance: .zero, transmittance: 1, depth: 0)
        }
        let dt = (t1 - t0) / Float(steps)
        let ph = phase(d.x * toSun.x + d.y * toSun.y + d.z * toSun.z) * 4 * Float.pi
        var T: Float = 1, L = SIMD3<Float>.zero, depthSum: Float = 0, wSum: Float = 0
        for i in 0..<steps {
            let t = t0 + (Float(i) + jitter) * dt
            let p = o + d * t
            let sigma = density(p, c)
            if sigma <= 0 { continue }
            let od = lightDepth(p, toSun, c)
            let h = (p.z - c.base) / c.thickness
            // Single scattering + multiple scattering approximated with Beer at a quarter extinction.
            let direct = sun * (ph * exp(-od) + 0.6 * exp(-0.25 * od))
            let powder = 1 - 0.6 * exp(-sigma * 120)
            let amb = skyAmbient * (0.35 + 0.65 * h) + groundAmbient * (0.35 * (1 - h))
            let S = (direct * powder + amb) * sigma   // albedo ≈ 1: scattering = extinction
            let Ts = exp(-sigma * dt)
            let integ = (S - S * Ts) / sigma           // ∫ S·T over the step (Hillaire 2016)
            L += T * integ
            let w = T * (1 - Ts)
            depthSum += w * t; wSum += w
            T *= Ts
            if T < 0.01 { break }
        }
        return CloudSample(radiance: L, transmittance: T, depth: wSum > 0 ? depthSum / wSum : 0)
    }

    /// Per-pixel jitter in [0, 1) (interleaved gradient noise; identical in MSL).
    public static func jitter(x: Int, y: Int) -> Float {
        let v = 52.982_918 * (0.067_110_56 * Float(x) + 0.005_837_15 * Float(y)).truncatingRemainder(dividingBy: 1)
        return v - v.rounded(.down)
    }
}
