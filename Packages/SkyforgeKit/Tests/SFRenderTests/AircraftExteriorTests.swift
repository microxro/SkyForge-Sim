// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFRender

@Suite struct AircraftExteriorTests {
    @Test func tiersAreMonotonic() {
        let k = ExteriorTier.allCases.map(AircraftExteriorKnobs.make)
        for i in 1..<k.count {
            #expect(k[i].propBlurSamples >= k[i - 1].propBlurSamples)
            #expect(k[i].detailDistance >= k[i - 1].detailDistance)
            #expect(k[i].rainLayers >= k[i - 1].rainLayers)
        }
        #expect(!k[0].rivets && k[3].clearcoat && k[3].vortices)
    }

    @Test func lightColoursFollowFAA() {
        let l = AircraftExteriorLights.sf1
        let left = l.first { $0.name == "left position" }!, right = l.first { $0.name == "right position" }!
        #expect(left.position.y < 0 && left.colour.x > 0.9 && left.colour.y < 0.1)         // red on port
        #expect(right.position.y > 0 && right.colour.y > 0.8 && right.colour.x < 0.1)      // green on starboard
        #expect(l.first { $0.name == "tail position" }!.position.x < -5)
        #expect(l.first { $0.kind == .beacon }!.colour.x > 0.9)
    }

    @Test func strobeRateIsInRegulatoryBand() {
        let s = AircraftExteriorLights.sf1.first { $0.kind == .strobe }!
        var flashes = 0, prev: Float = 0
        let dt: Float = 0.005
        var t: Float = 0
        while t < 60 { let i = AircraftExteriorLights.intensity(s, time: t); if i > 0.5 && prev <= 0.5 { flashes += 1 }; prev = i; t += dt }
        // Double flash: two flashes per 1.2 s cycle -> 50 cycles/min.
        let cyclesPerMin = Float(flashes) / 2
        #expect(cyclesPerMin >= 40 && cyclesPerMin <= 100, "\(cyclesPerMin)")
        #expect(AircraftExteriorLights.intensity(s, time: -0.5) >= 0)       // negative time is safe
    }

    @Test func beaconSweepsAndPositionLightsAreSteady() {
        let b = AircraftExteriorLights.sf1.first { $0.kind == .beacon }!
        let peak = AircraftExteriorLights.intensity(b, time: 0.175)
        #expect(peak > 0.95 && AircraftExteriorLights.intensity(b, time: 0.7) < 0.1)
        let p = AircraftExteriorLights.sf1[0]
        #expect(AircraftExteriorLights.intensity(p, time: 3.3) == 1)
    }

    @Test func glowShrinksWithDistanceAndIsCapped() {
        let near = AircraftExteriorLights.glowRadiusPixels(peak: 60, intensity: 1, distance: 10, pixelsPerRadian: 1500)
        let far = AircraftExteriorLights.glowRadiusPixels(peak: 60, intensity: 1, distance: 2_000, pixelsPerRadian: 1500)
        #expect(near > far && far >= 1.5 && near <= 48)
        #expect(AircraftExteriorLights.glowRadiusPixels(peak: 60, intensity: 0, distance: 10, pixelsPerRadian: 1500) == 0)
    }

    @Test func rivetsAreDomesAndFadeWithDistance() {
        let centre = AircraftSurfaceDetail.rivet(u: 0.032, v: 0.064, footprint: 0.001)
        #expect(centre.height > 0.99)
        let edge = AircraftSurfaceDetail.rivet(u: 0.032 + 0.004, v: 0.064, footprint: 0.001)
        #expect(edge.height > 0 && edge.height < 0.6 && edge.tilt.x < 0)     // tilts away from the dome centre
        let between = AircraftSurfaceDetail.rivet(u: 0.016, v: 0.016, footprint: 0.001)
        #expect(between.height == 0)
        #expect(AircraftSurfaceDetail.rivet(u: 0.032, v: 0.032, footprint: 0.05).fade == 0)
    }

    @Test func exhaustStainTrailsAftOnTheBelly() {
        let under = AircraftSurfaceDetail.exhaustStain(body: SIMD3(0.5, 0.0, 0.3))
        let top = AircraftSurfaceDetail.exhaustStain(body: SIMD3(0.5, 0.0, -0.8))
        let far = AircraftSurfaceDetail.exhaustStain(body: SIMD3(-4.0, 0.0, 0.3))
        let side = AircraftSurfaceDetail.exhaustStain(body: SIMD3(0.5, 0.5, 0.3))
        #expect(under > 0.2 && top == 0 && far < under && side < under)
        #expect(AircraftSurfaceDetail.exhaustStain(body: SIMD3(0.5, 0, 0.3), hours: 0) == 0)
        #expect(AircraftSurfaceDetail.dirt(body: SIMD3(0.5, 0, 0.3)) <= 1.9)
    }

    @Test func clearcoatFresnel() {
        #expect(abs(AircraftSurfaceDetail.clearcoatFresnel(cosTheta: 1) - 0.04) < 1e-5)
        #expect(AircraftSurfaceDetail.clearcoatFresnel(cosTheta: 0) > 0.99)
        #expect(AircraftSurfaceDetail.baseEnergy(cosTheta: 0.5) < 1)
    }

    @Test func rainStreaksFollowAirspeed() {
        #expect(AircraftRain.coverage(rainRate: 0, airspeed: 0) == 0)
        #expect(AircraftRain.coverage(rainRate: 10, airspeed: 0) > AircraftRain.coverage(rainRate: 10, airspeed: 70))
        #expect(AircraftRain.streakAngle(airspeed: 0) < AircraftRain.streakAngle(airspeed: 60))
        #expect(AircraftRain.streakLength(airspeed: 60) > AircraftRain.streakLength(airspeed: 0))
    }

    @Test func propDiscBlursWithRPM() {
        let slow = PropellerBlur.discOpacity(rpm: 30, blades: 2)
        let fast = PropellerBlur.discOpacity(rpm: 2_400, blades: 2)
        #expect(slow > fast && fast > 0 && fast < 0.3)
        // 2400 rpm, 2 blades = 80 passes/s; at 60 fps folds to 20 Hz (|rate| < fps/2 per blade).
        let r = PropellerBlur.aliasedRate(rpm: 2_400, blades: 2, fps: 60)
        #expect(abs(r) <= Float.pi * 60 / 2 * 1.001)
    }

    @Test func heatShimmerIsBehindAndFades() {
        #expect(HeatShimmer.amplitude(distanceAft: -1, lateral: 0, throttle: 1) == 0)
        #expect(HeatShimmer.amplitude(distanceAft: 1, lateral: 0, throttle: 1) > HeatShimmer.amplitude(distanceAft: 6, lateral: 0, throttle: 1))
        #expect(HeatShimmer.amplitude(distanceAft: 1, lateral: 0, throttle: 0) == 0)
        #expect(HeatShimmer.amplitude(distanceAft: 1, lateral: 3, throttle: 1) == 0)
    }

    @Test func contrailsNeedColdMoistAirAndJets() {
        #expect(ContrailModel.formation(temperatureC: -55, relativeHumidityIce: 1.1, jet: true) > 0.9)
        #expect(ContrailModel.formation(temperatureC: -20, relativeHumidityIce: 1.1, jet: true) == 0)
        #expect(ContrailModel.formation(temperatureC: -55, relativeHumidityIce: 0.4, jet: true) == 0)
        #expect(ContrailModel.formation(temperatureC: -55, relativeHumidityIce: 1.1, jet: false) < 0.2)
        #expect(ContrailModel.opacity(age: 0.1, persistence: 1) == 0)
        #expect(ContrailModel.radius(age: 60) > ContrailModel.radius(age: 1))
    }

    @Test func vorticesAppearUnderHighLoadInHumidAir() {
        // SF-1: 1,000 kg at 1 g, 11 m span, 35 m/s sea level.
        let g = WingtipVortex.circulation(lift: 9_800, airDensity: 1.225, airspeed: 35, span: 11)
        #expect(g > 20 && g < 60, "\(g)")
        let g2 = WingtipVortex.circulation(lift: 9_800 * 2.5, airDensity: 1.225, airspeed: 35, span: 11)
        #expect(WingtipVortex.visibility(circulation: g2, airDensity: 1.225, relativeHumidity: 0.95)
                >= WingtipVortex.visibility(circulation: g, airDensity: 1.225, relativeHumidity: 0.95))
        #expect(WingtipVortex.visibility(circulation: g * 0.25, airDensity: 1.225, relativeHumidity: 0.1) == 0)
    }
}
