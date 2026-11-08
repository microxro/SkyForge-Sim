// SKYFORGE — Apache-2.0
// Adapter from SFAtmosphere.SkyModel (y up, relative radiance) to the preview renderer (z up,
// renderer radiance units) with a precomputed aerial-perspective table.
import Foundation
import SFAtmosphere

public struct PhysicalSky: Sendable {
    public let model: SkyModel
    /// Renderer units per unit of solar irradiance (sun colour = transmittance × ks).
    public let ks: Float
    let nAz = 16, nEl = 32, nD = 32
    let maxDistanceKm: Double
    let inscatter: [SIMD3<Float>]
    let transmit: [SIMD3<Float>]
    let sunAzimuth: Double   // radians, in the renderer frame (atan2(y, x))

    /// `toSun` in the renderer frame (x east, y north, z up).
    public init(toSun: SIMD3<Float>, viewHeightMetres: Double, turbidity: Double = 1, ks: Float = 3.4, maxDistanceKm: Double = 90) {
        var p = AtmosphereParameters()
        p.turbidity = turbidity
        let el = asin(Double(max(-1, min(1, toSun.z)))) * 180 / .pi
        let az = atan2(Double(toSun.y), Double(toSun.x))
        model = SkyModel(sunElevationDeg: el, sunAzimuthDeg: az * 180 / .pi, viewHeightKm: max(0.002, viewHeightMetres / 1_000), parameters: p)
        self.ks = ks
        self.maxDistanceKm = maxDistanceKm
        sunAzimuth = az
        let nAz = 16, nEl = 32, nD = 32
        let dists = (1...nD).map { k in maxDistanceKm * pow(Double(k) / Double(nD), 2) }
        var ins = [SIMD3<Float>](repeating: .zero, count: nAz * nEl * nD)
        var tr = ins
        let scale = Float.pi * ks
        for j in 0..<nEl {
            let el = Self.elevation(forV: Double(j) / Double(nEl - 1))
            for i in 0..<nAz {
                let rel = Double(i) / Double(nAz - 1) * .pi
                let a = az + rel
                // SkyModel frame: y up; renderer x→x, y→z.
                let d = V3(cos(el) * cos(a), sin(el), cos(el) * sin(a))
                let slices = model.aerialSlices(d, distancesKm: dists)
                for k in 0..<nD {
                    let idx = (j * nAz + i) * nD + k
                    let (l, t) = slices[k]
                    ins[idx] = SIMD3(Float(l.x), Float(l.y), Float(l.z)) * scale
                    tr[idx] = SIMD3(Float(t.x), Float(t.y), Float(t.z))
                }
            }
        }
        inscatter = ins
        transmit = tr
    }

    static func elevation(forV v: Double) -> Double {
        let s = v * 2 - 1
        return (s < 0 ? -1 : 1) * s * s * (.pi / 2)
    }
    static func v(forElevation el: Double) -> Double {
        let s = (abs(el) / (.pi / 2)).squareRoot() * (el < 0 ? -1 : 1)
        return (s + 1) / 2
    }

    @inline(__always) func toModel(_ d: SIMD3<Float>) -> V3 { V3(Double(d.x), Double(d.z), Double(d.y)) }

    /// Sky radiance in renderer units (includes the sun disc).
    public func sky(_ d: SIMD3<Float>, sunDisc: Bool = true) -> SIMD3<Float> {
        let l = model.radiance(toModel(d), includeSun: sunDisc) * Double(Float.pi * ks)
        return SIMD3(Float(l.x), Float(l.y), Float(l.z))
    }

    public var sunColour: SIMD3<Float> {
        let t = model.sunTransmittance
        let vis: Float = model.sunDirection.y > -0.01 ? 1 : 0
        return SIMD3(Float(t.x), Float(t.y), Float(t.z)) * ks * vis
    }

    public var skyAmbient: SIMD3<Float> {
        let e = model.skyIrradiance
        return SIMD3(Float(e.x), Float(e.y), Float(e.z)) * ks
    }

    /// Aerial perspective toward direction `d` over `distanceMetres`: (in-scatter, transmittance).
    public func aerial(_ d: SIMD3<Float>, distanceMetres: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        let el = asin(Double(max(-1, min(1, d.z))))
        var rel = atan2(Double(d.y), Double(d.x)) - sunAzimuth
        rel = abs(remainder(rel, 2 * .pi))
        let fi = min(Double(nAz - 1), rel / .pi * Double(nAz - 1))
        let fj = min(Double(nEl - 1), max(0, Self.v(forElevation: el) * Double(nEl - 1)))
        let w = min(1, (Double(distanceMetres) / 1_000 / maxDistanceKm).squareRoot())
        let fk = w * Double(nD) - 1   // slice k holds distance ((k+1)/nD)²·max
        func at(_ i: Int, _ j: Int, _ kf: Double) -> (SIMD3<Float>, SIMD3<Float>) {
            if kf < 0 {
                // Between the eye (0, T=1) and the first slice.
                let f = Float(kf + 1)
                let idx = (j * nAz + i) * nD
                return (inscatter[idx] * f, SIMD3(repeating: 1) + (transmit[idx] - SIMD3(repeating: 1)) * f)
            }
            let k0 = min(nD - 1, Int(kf)), k1 = min(nD - 1, k0 + 1)
            let f = Float(kf - Double(k0))
            let a = (j * nAz + i) * nD
            return (inscatter[a + k0] + (inscatter[a + k1] - inscatter[a + k0]) * f,
                    transmit[a + k0] + (transmit[a + k1] - transmit[a + k0]) * f)
        }
        let i0 = Int(fi), j0 = Int(fj)
        let i1 = min(nAz - 1, i0 + 1), j1 = min(nEl - 1, j0 + 1)
        let fx = Float(fi - Double(i0)), fy = Float(fj - Double(j0))
        let a = at(i0, j0, fk), b = at(i1, j0, fk), c = at(i0, j1, fk), e = at(i1, j1, fk)
        let l0 = a.0 + (b.0 - a.0) * fx, l1 = c.0 + (e.0 - c.0) * fx
        let t0 = a.1 + (b.1 - a.1) * fx, t1 = c.1 + (e.1 - c.1) * fx
        return (l0 + (l1 - l0) * fy, t0 + (t1 - t0) * fy)
    }
}
