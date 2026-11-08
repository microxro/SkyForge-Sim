// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFAtmosphere

@Suite struct ScatteringTests {
    static let p = AtmosphereParameters()
    static let tLUT = SkyAtmosphere.computeTransmittance(p)

    @Test func zenithTransmittanceMatchesAnalyticOpticalDepth() {
        let p = Self.p
        let t = SkyAtmosphere.transmittance(Self.tLUT, r: p.bottomRadius + 0.001, mu: 1, p)
        // Rayleigh H·σ, Mie H·σ_ext, ozone tent area (2·width/2·…): width × σ_O3.
        let od = p.rayleighScattering * p.rayleighScaleHeight + p.mieExtinction * p.mieScaleHeight + p.ozoneAbsorption * p.ozoneWidth
        for k in 0..<3 { #expect(abs(t[k] - exp(-od[k])) < 0.006, "channel \(k): \(t[k]) vs \(exp(-od[k]))") }
        #expect(t.x > t.y && t.y > t.z)   // blue is scattered most
    }

    @Test func transmittanceParametrisationRoundTrips() {
        let p = Self.p
        for r in [p.bottomRadius + 0.01, p.bottomRadius + 3, p.bottomRadius + 40] {
            for mu in [-0.05, 0.0, 0.2, 0.7, 1.0] {
                guard SkyAtmosphere.rayToSphere(r: r, mu: mu, radius: p.bottomRadius) == nil else { continue }
                let (u, v) = SkyAtmosphere.transmittanceUV(r: r, mu: mu, p)
                let back = SkyAtmosphere.transmittanceRMu(u: u, v: v, p)
                #expect(abs(back.r - r) < 1e-6 && abs(back.mu - mu) < 1e-6, "r \(r) mu \(mu) → \(back)")
            }
        }
    }

    @Test func lowSunReddensSunlight() {
        let high = SkyModel(sunElevationDeg: 60).sunTransmittance
        let low = SkyModel(sunElevationDeg: 1).sunTransmittance
        #expect(high.z > 0.6)
        #expect(low.x / low.z > 4 * high.x / high.z)
    }

    @Test func noonZenithIsBlueAndSunsetHorizonIsWarm() {
        let noon = SkyModel(sunElevationDeg: 50)
        let z = noon.radiance(V3(0, 1, 0))
        #expect(z.z > z.y && z.y > z.x)
        let dusk = SkyModel(sunElevationDeg: 2)
        let towardSun = dusk.radiance(V3(cos(0.05), sin(0.05), 0), includeSun: false)
        #expect(towardSun.x > towardSun.z)
        let away = dusk.radiance(V3(-cos(0.3), sin(0.3), 0), includeSun: false)
        #expect((towardSun * towardSun).sum() > (away * away).sum())
    }

    @Test func multipleScatteringAddsLightAndSkyDarkensAtNight() {
        let ms = SkyModel(sunElevationDeg: 20)
        #expect(ms.multiScattering.data.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.z >= 0 && $0.x.isFinite })
        let night = SkyModel(sunElevationDeg: -18).radiance(V3(0, 1, 0))
        let day = ms.radiance(V3(0, 1, 0))
        #expect((night * night).sum() < 1e-4 * (day * day).sum())
    }

    @Test func aerialPerspectiveFadesDistantGround() {
        let m = SkyModel(sunElevationDeg: 30)
        let d = V3(0.99, -0.14, 0); let n = d / (d * d).sum().squareRoot()
        let (_, tNear) = m.aerialPerspective(n, distanceKm: 0.5)
        let (lFar, tFar) = m.aerialPerspective(n, distanceKm: 40)
        #expect(tNear.z > 0.95 && tFar.z < tNear.z && tFar.z < 0.7)
        #expect(lFar.z > lFar.x)   // haze is bluish at noon
    }

    @Test func lutsAreDeterministic() {
        let a = SkyAtmosphere.computeTransmittance(Self.p), b = SkyAtmosphere.computeTransmittance(Self.p)
        #expect(a.data == b.data)
    }
}
