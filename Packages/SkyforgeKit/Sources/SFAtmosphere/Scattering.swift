// SKYFORGE — Apache-2.0
// Physically based sky after Hillaire, "A Scalable and Production Ready Sky and Atmosphere
// Rendering Technique" (EGSR 2020): transmittance LUT, multiple-scattering LUT and sky-view LUT.
// This CPU implementation is the reference for the Metal compute version and the source of the
// CPU preview sky. Lengths in km, coefficients per km.
import Foundation

public typealias V3 = SIMD3<Double>

public struct AtmosphereParameters: Sendable, Equatable {
    public var bottomRadius = 6_360.0
    public var topRadius = 6_460.0
    public var rayleighScattering = V3(5.802, 13.558, 33.1) * 1e-3
    public var rayleighScaleHeight = 8.0
    public var mieScattering = V3(repeating: 3.996e-3)
    public var mieExtinction = V3(repeating: 4.40e-3)
    public var mieScaleHeight = 1.2
    public var mieG = 0.8
    public var ozoneAbsorption = V3(0.650, 1.881, 0.085) * 1e-3
    public var ozoneCenter = 25.0
    public var ozoneWidth = 15.0
    public var groundAlbedo = V3(repeating: 0.3)
    /// Solar irradiance at the top of the atmosphere (relative units).
    public var solarIrradiance = V3(repeating: 1.0)
    public var sunAngularRadius = 0.004675   // rad
    public init() {}

    /// Haze multiplier on Mie density (1 = clear; METAR visibility maps onto this).
    public var turbidity = 1.0

    @inline(__always) func densities(_ h: Double) -> (rayleigh: Double, mie: Double, ozone: Double) {
        let hr = exp(-max(0, h) / rayleighScaleHeight)
        let hm = exp(-max(0, h) / mieScaleHeight) * turbidity
        let ho = max(0, 1 - abs(h - ozoneCenter) / ozoneWidth)
        return (hr, hm, ho)
    }

    func extinction(_ h: Double) -> V3 {
        let d = densities(h)
        return rayleighScattering * d.rayleigh + mieExtinction * d.mie + ozoneAbsorption * d.ozone
    }
}

public struct LUT2D: Sendable {
    public let width: Int, height: Int
    public var data: [SIMD3<Float>]
    init(width: Int, height: Int) { self.width = width; self.height = height; data = .init(repeating: .zero, count: width * height) }

    public subscript(x: Int, y: Int) -> SIMD3<Float> {
        get { data[y * width + x] }
        set { data[y * width + x] = newValue }
    }

    /// Bilinear sample at uv in [0,1]² (texel centres at (i+0.5)/n, clamp to edge).
    public func sample(_ u: Double, _ v: Double) -> V3 {
        let x = min(max(u * Double(width) - 0.5, 0), Double(width - 1))
        let y = min(max(v * Double(height) - 0.5, 0), Double(height - 1))
        let x0 = Int(x), y0 = Int(y)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        let a = self[x0, y0] + (self[x1, y0] - self[x0, y0]) * fx
        let b = self[x0, y1] + (self[x1, y1] - self[x0, y1]) * fx
        let c = a + (b - a) * fy
        return V3(Double(c.x), Double(c.y), Double(c.z))
    }
}

public enum SkyAtmosphere {
    public static let transmittanceSize = (w: 256, h: 64)
    public static let multiScatteringSize = 32
    public static let skyViewSize = (w: 192, h: 108)

    // MARK: geometry helpers

    /// Distance to the sphere of radius R from radius r along cos-zenith mu (nil when missed).
    @inline(__always) static func rayToSphere(r: Double, mu: Double, radius R: Double) -> Double? {
        let disc = r * r * (mu * mu - 1) + R * R
        guard disc >= 0 else { return nil }
        let s = disc.squareRoot()
        let t1 = -r * mu - s, t2 = -r * mu + s
        if t1 > 0 { return t1 }
        return t2 > 0 ? t2 : nil
    }

    static func rayleighPhase(_ c: Double) -> Double { 3 / (16 * .pi) * (1 + c * c) }
    static func miePhase(_ c: Double, _ g: Double) -> Double {
        // Cornette–Shanks
        let k = 3 / (8 * .pi) * (1 - g * g) / (2 + g * g)
        return k * (1 + c * c) / pow(1 + g * g - 2 * g * c, 1.5)
    }

    // MARK: transmittance LUT (Bruneton parametrisation)

    public static func transmittanceUV(r: Double, mu: Double, _ p: AtmosphereParameters) -> (Double, Double) {
        let H = (p.topRadius * p.topRadius - p.bottomRadius * p.bottomRadius).squareRoot()
        let rho = max(0, r * r - p.bottomRadius * p.bottomRadius).squareRoot()
        let disc = r * r * (mu * mu - 1) + p.topRadius * p.topRadius
        let d = max(0, -r * mu + max(0, disc).squareRoot())
        let dMin = p.topRadius - r, dMax = rho + H
        return ((d - dMin) / max(1e-9, dMax - dMin), rho / H)
    }

    static func transmittanceRMu(u: Double, v: Double, _ p: AtmosphereParameters) -> (r: Double, mu: Double) {
        let H = (p.topRadius * p.topRadius - p.bottomRadius * p.bottomRadius).squareRoot()
        let rho = H * v
        let r = (rho * rho + p.bottomRadius * p.bottomRadius).squareRoot()
        let dMin = p.topRadius - r, dMax = rho + H
        let d = dMin + u * (dMax - dMin)
        let mu = d == 0 ? 1 : max(-1, min(1, (H * H - rho * rho - d * d) / (2 * r * d)))
        return (r, mu)
    }

    public static func computeTransmittance(_ p: AtmosphereParameters, steps: Int = 40) -> LUT2D {
        var lut = LUT2D(width: transmittanceSize.w, height: transmittanceSize.h)
        for y in 0..<lut.height {
            for x in 0..<lut.width {
                let (r, mu) = transmittanceRMu(u: (Double(x) + 0.5) / Double(lut.width), v: (Double(y) + 0.5) / Double(lut.height), p)
                let t = rayToSphere(r: r, mu: mu, radius: p.topRadius) ?? 0
                var od = V3.zero
                let dt = t / Double(steps)
                for i in 0..<steps {
                    let s = (Double(i) + 0.5) * dt
                    let ri = (r * r + s * s + 2 * r * mu * s).squareRoot()
                    od += p.extinction(ri - p.bottomRadius) * dt
                }
                let tr = V3(exp(-od.x), exp(-od.y), exp(-od.z))
                lut[x, y] = SIMD3<Float>(Float(tr.x), Float(tr.y), Float(tr.z))
            }
        }
        return lut
    }

    static func transmittance(_ lut: LUT2D, r: Double, mu: Double, _ p: AtmosphereParameters) -> V3 {
        let (u, v) = transmittanceUV(r: r, mu: mu, p)
        return lut.sample(u, v)
    }

    // MARK: multiple scattering LUT

    public static func computeMultiScattering(_ p: AtmosphereParameters, transmittance tLUT: LUT2D,
                                              directions: Int = 8, steps: Int = 20) -> LUT2D {
        let n = multiScatteringSize
        var lut = LUT2D(width: n, height: n)
        let uniformPhase = 1 / (4 * Double.pi)
        for y in 0..<n {
            for x in 0..<n {
                let cosSun = (Double(x) + 0.5) / Double(n) * 2 - 1
                let r = p.bottomRadius + (Double(y) + 0.5) / Double(n) * (p.topRadius - p.bottomRadius)
                let sunDir = V3((1 - cosSun * cosSun).squareRoot(), cosSun, 0)
                var lum = V3.zero, fms = V3.zero
                let count = directions * directions
                for j in 0..<directions {
                    for i in 0..<directions {
                        let theta = acos(1 - 2 * (Double(j) + 0.5) / Double(directions))
                        let phi = 2 * Double.pi * (Double(i) + 0.5) / Double(directions)
                        let dir = V3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
                        let (l, f) = integrateMS(r: r, dir: dir, sunDir: sunDir, p, tLUT, steps: steps, uniformPhase: uniformPhase)
                        lum += l; fms += f
                    }
                }
                let sphere = 4 * Double.pi / Double(count)
                let l2 = lum * sphere * uniformPhase
                let f = fms * sphere * uniformPhase
                let psi = l2 / (V3(repeating: 1) - f)
                lut[x, y] = SIMD3<Float>(Float(psi.x), Float(psi.y), Float(psi.z))
            }
        }
        return lut
    }

    private static func integrateMS(r: Double, dir: V3, sunDir: V3, _ p: AtmosphereParameters, _ tLUT: LUT2D,
                                    steps: Int, uniformPhase: Double) -> (V3, V3) {
        let mu = dir.y
        let ground = rayToSphere(r: r, mu: mu, radius: p.bottomRadius)
        guard let tTop = ground ?? rayToSphere(r: r, mu: mu, radius: p.topRadius) else { return (.zero, .zero) }
        let dt = tTop / Double(steps)
        var L = V3.zero, F = V3.zero, T = V3(repeating: 1)
        let origin = V3(0, r, 0)
        for i in 0..<steps {
            let s = (Double(i) + 0.5) * dt
            let pos = origin + dir * s
            let ri = (pos * pos).sum().squareRoot()
            let h = ri - p.bottomRadius
            let d = p.densities(h)
            let scat = p.rayleighScattering * d.rayleigh + p.mieScattering * d.mie
            let ext = p.extinction(h)
            let stepT = V3(exp(-ext.x * dt), exp(-ext.y * dt), exp(-ext.z * dt))
            let up = pos / ri
            let sunT = transmittance(tLUT, r: ri, mu: (up * sunDir).sum(), p)
            let S = sunT * scat * uniformPhase
            let safeExt = V3(max(ext.x, 1e-12), max(ext.y, 1e-12), max(ext.z, 1e-12))
            L += T * (S - S * stepT) / safeExt
            F += T * (scat - scat * stepT) / safeExt
            T *= stepT
        }
        if ground != nil {
            // Lambertian ground bounce.
            let pos = origin + dir * tTop
            let up = pos / (pos * pos).sum().squareRoot()
            let nl = max(0, (up * sunDir).sum())
            L += T * transmittance(tLUT, r: p.bottomRadius, mu: (up * sunDir).sum(), p) * nl * p.groundAlbedo / .pi
        }
        return (L, F)
    }

    // MARK: sky-view LUT

    /// Latitude mapping that concentrates texels near the horizon (Hillaire eq. 3).
    public static func skyViewUV(viewZenithCos: Double, azimuth: Double, r: Double, _ p: AtmosphereParameters) -> (Double, Double) {
        let horizon = horizonZenith(r: r, p)
        let zenith = acos(max(-1, min(1, viewZenithCos)))
        let v: Double
        if zenith < horizon {
            let c = zenith / horizon
            v = 0.5 * (1 - (1 - c).squareRoot())
        } else {
            let c = (zenith - horizon) / (.pi - horizon)
            v = 0.5 + 0.5 * c.squareRoot()
        }
        return (min(1, max(0, azimuth / (2 * .pi))), v)
    }

    static func horizonZenith(r: Double, _ p: AtmosphereParameters) -> Double {
        .pi - asin(min(1, p.bottomRadius / r))
    }

    public static func computeSkyView(_ p: AtmosphereParameters, transmittance tLUT: LUT2D, multiScattering ms: LUT2D,
                                      viewHeightKm: Double, sunZenithCos: Double, steps: Int = 32) -> LUT2D {
        var lut = LUT2D(width: skyViewSize.w, height: skyViewSize.h)
        let r = p.bottomRadius + max(0.001, viewHeightKm)
        let horizon = horizonZenith(r: r, p)
        let sunDir = V3((1 - sunZenithCos * sunZenithCos).squareRoot(), sunZenithCos, 0)
        for y in 0..<lut.height {
            let v = (Double(y) + 0.5) / Double(lut.height)
            let zenith: Double
            if v < 0.5 {
                let c = 1 - 2 * v
                zenith = horizon * (1 - c * c)
            } else {
                let c = 2 * v - 1
                zenith = horizon + (.pi - horizon) * c * c
            }
            for x in 0..<lut.width {
                let az = (Double(x) + 0.5) / Double(lut.width) * 2 * .pi
                let dir = V3(sin(zenith) * cos(az), cos(zenith), sin(zenith) * sin(az))
                let l = raymarchScattering(r: r, dir: dir, sunDir: sunDir, p, tLUT, ms, steps: steps)
                lut[x, y] = SIMD3<Float>(Float(l.x), Float(l.y), Float(l.z))
            }
        }
        return lut
    }

    /// Single scattering with the multiple-scattering term; returns luminance (relative units).
    public static func raymarchScattering(r: Double, dir: V3, sunDir: V3, _ p: AtmosphereParameters, _ tLUT: LUT2D, _ ms: LUT2D,
                                          steps: Int, maxDistance: Double = .infinity) -> V3 {
        let mu = dir.y
        let ground = rayToSphere(r: r, mu: mu, radius: p.bottomRadius)
        guard var tMax = ground ?? rayToSphere(r: r, mu: mu, radius: p.topRadius) else { return .zero }
        tMax = min(tMax, maxDistance)
        let cosTheta = (dir * sunDir).sum()
        let phaseR = rayleighPhase(cosTheta), phaseM = miePhase(cosTheta, p.mieG)
        let origin = V3(0, r, 0)
        var L = V3.zero, T = V3(repeating: 1)
        // Quadratic step distribution: denser near the eye.
        var prev = 0.0
        for i in 0..<steps {
            let t1 = tMax * pow((Double(i) + 1) / Double(steps), 2)
            let dt = t1 - prev
            let s = prev + dt * 0.5
            prev = t1
            let pos = origin + dir * s
            let ri = (pos * pos).sum().squareRoot()
            let h = ri - p.bottomRadius
            let d = p.densities(h)
            let scatR = p.rayleighScattering * d.rayleigh, scatM = p.mieScattering * d.mie
            let ext = p.extinction(h)
            let up = pos / ri
            let sunMu = (up * sunDir).sum()
            let sunT = transmittance(tLUT, r: ri, mu: sunMu, p)
            // Earth shadow: sun below the local horizon contributes nothing directly.
            let visible = rayToSphere(r: ri, mu: sunMu, radius: p.bottomRadius) == nil ? 1.0 : 0.0
            let msU = sunMu * 0.5 + 0.5, msV = h / (p.topRadius - p.bottomRadius)
            let psi = ms.sample(msU, msV)
            let S = (sunT * visible * (scatR * phaseR + scatM * phaseM) + psi * (scatR + scatM)) * p.solarIrradiance
            let stepT = V3(exp(-ext.x * dt), exp(-ext.y * dt), exp(-ext.z * dt))
            let safeExt = V3(max(ext.x, 1e-12), max(ext.y, 1e-12), max(ext.z, 1e-12))
            L += T * (S - S * stepT) / safeExt
            T *= stepT
        }
        return L
    }
}

/// Precomputed sky for one sun position and viewer height; samples radiance by direction.
public struct SkyModel: Sendable {
    public let parameters: AtmosphereParameters
    public let transmittance: LUT2D
    public let multiScattering: LUT2D
    public let skyView: LUT2D
    public let sunDirection: V3    // y up, normalised
    public let viewHeightKm: Double

    public init(sunElevationDeg: Double, sunAzimuthDeg: Double = 0, viewHeightKm: Double = 0.2,
                parameters: AtmosphereParameters = AtmosphereParameters()) {
        self.parameters = parameters
        self.viewHeightKm = viewHeightKm
        let el = sunElevationDeg * .pi / 180, az = sunAzimuthDeg * .pi / 180
        sunDirection = V3(cos(el) * cos(az), sin(el), cos(el) * sin(az))
        transmittance = SkyAtmosphere.computeTransmittance(parameters)
        multiScattering = SkyAtmosphere.computeMultiScattering(parameters, transmittance: transmittance)
        skyView = SkyAtmosphere.computeSkyView(parameters, transmittance: transmittance, multiScattering: multiScattering,
                                               viewHeightKm: viewHeightKm, sunZenithCos: sin(el))
    }

    /// Radiance toward unit direction `d` (y up), including the solar disc.
    public func radiance(_ d: V3, includeSun: Bool = true) -> V3 {
        let p = parameters
        let r = p.bottomRadius + viewHeightKm
        // Azimuth relative to the sun around the up axis.
        let sunAz = atan2(sunDirection.z, sunDirection.x)
        var az = atan2(d.z, d.x) - sunAz
        if az < 0 { az += 2 * .pi }
        let (u, v) = SkyAtmosphere.skyViewUV(viewZenithCos: d.y, azimuth: az, r: r, p)
        var L = skyView.sample(u, v)
        if includeSun {
            let c = (d * sunDirection).sum()
            if c > cos(p.sunAngularRadius) && SkyAtmosphere.rayToSphere(r: r, mu: d.y, radius: p.bottomRadius) == nil {
                let t = SkyAtmosphere.transmittance(transmittance, r: r, mu: d.y, p)
                // Disc radiance ≈ irradiance / solid angle, limb-darkened.
                let solid = Double.pi * p.sunAngularRadius * p.sunAngularRadius
                let rho = acos(min(1, c)) / p.sunAngularRadius
                let mu = max(0, 1 - rho * rho).squareRoot()
                L += t * p.solarIrradiance / solid * (0.4 + 0.6 * mu)
            }
        }
        return L
    }

    /// Transmittance from the viewer toward the sun (sunlight colour at the viewer).
    public var sunTransmittance: V3 {
        let r = parameters.bottomRadius + viewHeightKm
        return SkyAtmosphere.transmittance(transmittance, r: r, mu: sunDirection.y, parameters)
    }

    /// Aerial perspective for a segment of length `distanceKm` along `d`: (in-scattered radiance, transmittance).
    public func aerialPerspective(_ d: V3, distanceKm: Double, steps: Int = 12) -> (V3, V3) {
        let p = parameters
        let r = p.bottomRadius + viewHeightKm
        let L = SkyAtmosphere.raymarchScattering(r: r, dir: d, sunDir: sunDirection, p, transmittance, multiScattering,
                                                 steps: steps, maxDistance: distanceKm)
        var od = V3.zero
        let n = 8
        for i in 0..<n {
            let s = (Double(i) + 0.5) / Double(n) * distanceKm
            let pos = V3(0, r, 0) + d * s
            od += p.extinction((pos * pos).sum().squareRoot() - p.bottomRadius) * (distanceKm / Double(n))
        }
        return (L, V3(exp(-od.x), exp(-od.y), exp(-od.z)))
    }
}

extension SkyModel {
    /// Cumulative aerial perspective along `d` at increasing distances (km): (in-scattered radiance, transmittance).
    public func aerialSlices(_ d: V3, distancesKm: [Double], substeps: Int = 4) -> [(V3, V3)] {
        let p = parameters
        let r = p.bottomRadius + viewHeightKm
        let origin = V3(0, r, 0)
        let cosTheta = (d * sunDirection).sum()
        let phaseR = SkyAtmosphere.rayleighPhase(cosTheta), phaseM = SkyAtmosphere.miePhase(cosTheta, p.mieG)
        var L = V3.zero, T = V3(repeating: 1), prev = 0.0
        var out: [(V3, V3)] = []
        out.reserveCapacity(distancesKm.count)
        for target in distancesKm {
            let seg = max(0, target - prev)
            let dt = seg / Double(substeps)
            for k in 0..<substeps where dt > 0 {
                let s = prev + (Double(k) + 0.5) * dt
                let pos = origin + d * s
                let ri = (pos * pos).sum().squareRoot()
                let h = ri - p.bottomRadius
                let dens = p.densities(h)
                let scatR = p.rayleighScattering * dens.rayleigh, scatM = p.mieScattering * dens.mie
                let ext = p.extinction(h)
                let up = pos / ri
                let sunMu = (up * sunDirection).sum()
                let sunT = SkyAtmosphere.transmittance(transmittance, r: ri, mu: sunMu, p)
                let visible = SkyAtmosphere.rayToSphere(r: ri, mu: sunMu, radius: p.bottomRadius) == nil ? 1.0 : 0.0
                let psi = multiScattering.sample(sunMu * 0.5 + 0.5, max(0, h) / (p.topRadius - p.bottomRadius))
                let S = (sunT * visible * (scatR * phaseR + scatM * phaseM) + psi * (scatR + scatM)) * p.solarIrradiance
                let stepT = V3(exp(-ext.x * dt), exp(-ext.y * dt), exp(-ext.z * dt))
                let safeExt = V3(max(ext.x, 1e-12), max(ext.y, 1e-12), max(ext.z, 1e-12))
                L += T * (S - S * stepT) / safeExt
                T *= stepT
            }
            prev = max(prev, target)
            out.append((L, T))
        }
        return out
    }

    /// Cosine-weighted sky irradiance on an upward-facing surface (no sun disc).
    public var skyIrradiance: V3 {
        var e = V3.zero
        let n = 12
        for j in 0..<n {
            for i in 0..<(2 * n) {
                let ct = (Double(j) + 0.5) / Double(n)      // uniform in cos θ ⇒ cosine weight below
                let st = (1 - ct * ct).squareRoot()
                let az = (Double(i) + 0.5) / Double(2 * n) * 2 * .pi
                e += radiance(V3(st * cos(az), ct, st * sin(az)), includeSun: false) * ct
            }
        }
        return e * (2 * .pi / Double(n * 2 * n))
    }
}
