// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFRender

@Suite struct NightTests {
    // 2000-01-06 18:14 UTC was a new moon; 2000-01-21 04:40 UTC a full moon.
    static let newMoon = 947_182_440.0
    static let fullMoon = 948_429_600.0

    @Test func moonPhaseNewAndFull() {
        let n = Astro.moonPhase(d: Astro.daysSinceJ2000(unix: Self.newMoon))
        let f = Astro.moonPhase(d: Astro.daysSinceJ2000(unix: Self.fullMoon))
        #expect(n.illuminated < 0.06)
        #expect(f.illuminated > 0.94)
        #expect(f.phaseAngleDeg < 20)
    }

    @Test func sunPositionAtEquinox() {
        // 2000-03-20 07:35 UTC: RA ~ 0, dec ~ 0.
        let d = Astro.daysSinceJ2000(unix: 953_537_700)
        let s = Astro.sun(d: d)
        #expect(abs(s.decDeg) < 0.6)
        #expect(min(s.raDeg, 360 - s.raDeg) < 1.0)
    }

    @Test func celestialPoleElevationEqualsLatitude() {
        let v = Astro.equatorialToENU(SIMD3(0, 0, 1), latDeg: 47, lstDeg: 123)
        #expect(abs(Astro.elevationDeg(v) - 47) < 1e-9)
        #expect(abs(v.x) < 1e-9 && v.y > 0)
        // Rotation preserves length.
        let w = Astro.equatorialToENU(SIMD3(0.3, -0.5, 0.2), latDeg: -33, lstDeg: 10)
        #expect(abs((w * w).sum() - 0.38) < 1e-9)
    }

    @Test func sunNoonElevationAtSolstice() {
        // Local solar noon near lon 0, 2000-06-21: elevation ~ 90 - lat + 23.4.
        var best = -90.0
        let base = 961_545_600.0 // 2000-06-21 00:00 UTC
        for m in stride(from: 0, to: 1440, by: 5) {
            let st = NightSkyState(unix: base + Double(m) * 60, latDeg: 45, lonDeg: 0)
            best = max(best, Double(st.sunElevationDeg))
        }
        #expect(abs(best - 68.4) < 1.0)
    }

    @Test func starFieldDeterministicAndBounded() {
        let a = StarField.generate(tier: .medium), b = StarField.generate(tier: .medium)
        #expect(a == b)
        #expect(a.count == NightTier.medium.starCount)
        for s in a {
            #expect(abs((s.direction * s.direction).sum() - 1) < 1e-4)
            #expect(s.magnitude <= NightTier.medium.starLimitMagnitude + 1e-3 && s.magnitude >= -1.01)
            #expect(max(s.color.x, s.color.y, s.color.z) <= 1.0001 && min(s.color.x, s.color.y, s.color.z) > 0)
        }
        // Faint stars dominate.
        #expect(a.filter { $0.magnitude > 3 }.count > a.filter { $0.magnitude <= 3 }.count)
        #expect(StarField.pack(a).count == a.count * 2)
    }

    @Test func tiersScale() {
        let counts = NightTier.allCases.map(\.starCount)
        #expect(counts == counts.sorted())
        let lights = NightTier.allCases.map(\.maxLightSprites)
        #expect(lights == lights.sorted())
    }

    @Test func limitingMagnitudeMonotonicWithDarkness() {
        var prev: Float = -100
        for e in stride(from: Float(10), through: -25, by: -0.5) {
            let m = NightModel.limitingMagnitude(sunElevationDeg: e)
            #expect(m >= prev); prev = m
        }
        #expect(NightModel.limitingMagnitude(sunElevationDeg: -30) == 6.5)
        #expect(NightModel.darkness(sunElevationDeg: 10) == 0)
        #expect(NightModel.darkness(sunElevationDeg: -20) == 1)
    }

    @Test func twilightWarmPeaksNearHorizon() {
        let day = NightModel.twilight(sunElevationDeg: 30)
        let set = NightModel.twilight(sunElevationDeg: -1)
        let deep = NightModel.twilight(sunElevationDeg: -20)
        #expect(set.horizonWarm.x > day.horizonWarm.x)
        #expect(set.horizonWarm.x > deep.horizonWarm.x)
        #expect(deep.exposureBoost > day.exposureBoost)
        #expect(day.exposureBoost == 1)
    }

    @Test func moonlightAndAirglow() {
        let full = NightModel.moonlightLux(phaseAngleDeg: 0, elevationDeg: 90)
        #expect(abs(full - 0.267) < 0.01)
        #expect(NightModel.moonlightLux(phaseAngleDeg: 0, elevationDeg: -5) == 0)
        #expect(NightModel.moonlightLux(phaseAngleDeg: 90, elevationDeg: 60) < full / 5)
        #expect(abs(NightModel.airglowEnhancement(elevationDeg: 90) - 1) < 1e-4)
        #expect(NightModel.airglowEnhancement(elevationDeg: 5) > 1.8)
    }

    @Test func milkyWayDensityFollowsGalacticPlane() {
        let onPlane = StarField.galacticCentre
        #expect(StarField.milkyWayDensity(onPlane) > 0.9)
        #expect(StarField.milkyWayDensity(StarField.galacticPole) < 0.01)
    }

    @Test func papiLamps() {
        #expect(PAPI.whiteCount(angleDeg: 4.0) == 4)
        #expect(PAPI.whiteCount(angleDeg: 3.3) == 3)
        #expect(PAPI.whiteCount(angleDeg: 3.0) == 2)
        #expect(PAPI.whiteCount(angleDeg: 2.6) == 1)
        #expect(PAPI.whiteCount(angleDeg: 2.0) == 0)
        #expect(PAPI.whiteFraction(lamp: 0, angleDeg: 2.0) == 0 && PAPI.whiteFraction(lamp: 0, angleDeg: 3) == 1)
        let a = PAPI.viewAngleDeg(aircraftRelative: SIMD3(1000, 0, 52.4))
        #expect(abs(a - 3.0) < 0.01)
    }

    @Test func lightColoursAreCorrect() {
        #expect(LightKind.threshold.color.y > 0.9 && LightKind.threshold.color.x < 0.2)
        #expect(LightKind.runwayEnd.color.x > 0.9 && LightKind.runwayEnd.color.y < 0.1)
        #expect(LightKind.taxiEdge.color.z > 0.9 && LightKind.taxiEdge.color.x < 0.2)
        #expect(LightKind.runwayEdgeCaution.color.x > 0.9 && LightKind.runwayEdgeCaution.color.z < 0.2)
        #expect(LightKind.navRed.color.x > 0.9 && LightKind.navGreen.color.y > 0.9)
    }

    @Test func spriteSizingIsContinuousAndConservesEnergy() {
        var prevE: Float = -1, prevS: Float = -1
        for d in stride(from: Float(10), through: 3000, by: 5) {
            let m = LightSprite.metrics(radiusMetres: 0.45, distance: d, focalPixels: 1000, minPixels: 1.6, maxDistance: 40_000)
            #expect(m.pixelSize >= 1.6 - 1e-4)
            // sprite area * energy never rises as the light recedes
            let e = m.energyScale
            if prevE >= 0 { #expect(e <= prevE + 1e-5); #expect(abs(e - prevE) < 0.2) }
            prevE = e; prevS = m.pixelSize
        }
        _ = prevS
        let edge = LightSprite.metrics(radiusMetres: 0.45, distance: 40_000, focalPixels: 1000, minPixels: 1.6, maxDistance: 40_000)
        #expect(edge.energyScale == 0)
        #expect(LightSprite.metrics(radiusMetres: 50, distance: 1, focalPixels: 1000, minPixels: 1.6, maxDistance: 40_000).pixelSize == LightSprite.maxPixelSize)
        // reversed-Z: nearer lights get larger depth, so a light behind terrain fails the .greater test
        #expect(LightSprite.reversedDepth(near: 0.5, viewZ: 100) > LightSprite.reversedDepth(near: 0.5, viewZ: 5_000))
        #expect(LightSprite.reversedDepth(near: 0.5, viewZ: 0.5) == 1)
        #expect(LightSprite.beamGain(cosAngle: 1, halfAngleDeg: 7.5) == 1)
        #expect(LightSprite.beamGain(cosAngle: 0, halfAngleDeg: 7.5) == 0)
        #expect(LightSprite.beamGain(cosAngle: -1, halfAngleDeg: 180) == 1)
        #expect(LightSprite.strobe(time: 0.01, phase: 0) == 1 && LightSprite.strobe(time: 0.1, phase: 0) == 0)
    }

    @Test func runwayLayout() {
        let l = AirportLighting.runway(centre: .zero, headingRad: 0, length: 2400, width: 45)
        #expect(l.contains { $0.kind == .threshold } && l.contains { $0.kind == .runwayEnd })
        #expect(l.contains { $0.kind == .runwayEdgeCaution } && l.contains { $0.kind == .approach })
        // Edge lights straddle the centreline symmetrically.
        let edges = l.filter { $0.kind == .runwayEdge || $0.kind == .runwayEdgeCaution }
        #expect(abs(edges.map(\.position.x).reduce(0, +)) < 1e-2)
        #expect(l.allSatisfy { $0.packed().count == 4 })
        let p = AirportLighting.papi(thresholdPoint: .zero, headingRad: 0, runwayHalfWidth: 22.5)
        #expect(p.count == 4 && p.allSatisfy { $0.position.x < -22 })
    }

    @Test func runwayLightsFollowTheRunwayDirection() {
        // Runway 090: threshold at the origin, course due east (ENU x). Lights must lie along +x, centred 1200 m east.
        let l = AirportLighting.runwayLights(threshold: SIMD2(0, 0), direction: SIMD2(1, 0), length: 2400, width: 45)
        #expect(!l.isEmpty && l.count <= 512)   // NightLightPass.maxLights
        let centre = l.filter { $0.kind == .centreline }.map(\.position.x)
        #expect(abs((centre.min() ?? 0) - 0) < 1 && abs((centre.max() ?? 0) - 2400) < 1)
        #expect(AirportLighting.runwayLights(threshold: .zero, direction: .zero, length: 2400, width: 45).isEmpty)
    }

    @Test func cityLightsDeterministicAndDensityOrdered() {
        let cell = CityLights.Cell(x: 3, y: -2)
        let a = CityLights.lights(cell: cell, density: 0.8), b = CityLights.lights(cell: cell, density: 0.8)
        #expect(a == b)
        let sparse = CityLights.lights(cell: cell, density: 0.2)
        #expect(a.count > sparse.count && !sparse.isEmpty)
        #expect(CityLights.lights(cell: cell, density: 0.0).isEmpty)
        for x in a { #expect(x.position.x >= 1200 && x.position.x <= 1600 + 4 && x.position.y >= -800 - 1 && x.position.y <= -400 + 4) }
        #expect(CityLights.lights(cell: cell, density: 1, budget: 50).count <= 50)
        #expect(CityLights.density(landUse: "commercial", buildingCoverage: 0.5) > CityLights.density(landUse: "forest", buildingCoverage: 0))
        let cells = CityLights.visibleCells(camera: SIMD2(10, 10), tier: .high)
        #expect(cells.count == 49 && cells.first == CityLights.Cell(x: 0, y: 0))
    }

    @Test func coneLightFocusesAhead() {
        let c = ConeLight.landing(position: SIMD3(0, 0, 10), forward: SIMD3(0, 1, 0))
        let ahead = c.irradiance(at: SIMD3(0, 100, 10 - 100 * tan(4 * .pi / 180)))
        let side = c.irradiance(at: SIMD3(100, 0, 0))
        let behind = c.irradiance(at: SIMD3(0, -100, 0))
        #expect(ahead > 0 && side == 0 && behind == 0)
        #expect(c.irradiance(at: SIMD3(0, 2000, 0)) == 0)
    }

    @Test func uniformLayoutAndPacking() {
        #expect(MemoryLayout<NightSkyUniforms>.stride == 16 * 16)
        #expect(MemoryLayout<NightConeUniform>.stride == 4 * 16)
        let st = NightSkyState(unix: Self.fullMoon, latDeg: 40, lonDeg: -100)
        let u = NightSkyUniforms(state: st, tier: .high, right: SIMD3(1, 0, 0), up: SIMD3(0, 0, 1), forward: SIMD3(0, 1, 0),
                                 verticalFOV: 1, viewport: SIMD2(1920, 1080), time: 0)
        #expect(u.view.x > u.view.y)
        #expect(NightShaders.source.contains("nt_cone_light") && NightShaders.source.contains("nt_sky_fragment"))
    }
}
