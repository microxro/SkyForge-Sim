// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFInstruments
import SFFlightModel
import SFAtmosphere
import SFMath

@Suite struct GaugeMathTests {
    @Test func altimeterHandsReadTwelveThreeFortyFive() {
        let h = GaugeMath.altimeterHands(12_345)
        #expect(abs(h.hundreds - 124.2) < 1e-9)       // 345 ft of a 1,000 ft turn
        #expect(abs(h.thousands - 0.2345 * 360) < 1e-9)
        #expect(abs(h.tenThousands - 0.12345 * 360) < 1e-9)
        #expect(GaugeMath.altimeterHands(-250).hundreds > 260)  // below datum wraps, never negative
    }

    @Test func airspeedDialIsMonotonicAndBounded() {
        var last = -1.0
        for kt in stride(from: 0.0, through: 220, by: 1) {
            let a = GaugeMath.airspeedAngle(kt)
            #expect(a >= last)
            last = a
        }
        #expect(GaugeMath.airspeedAngle(40) == 30)
        #expect(GaugeMath.airspeedAngle(200) == 340)
        #expect(GaugeMath.airspeedAngle(500) < 360)
    }

    @Test func vsiIsSymmetricAndSaturates() {
        #expect(GaugeMath.verticalSpeedAngle(0) == -90)
        for v in [300.0, 1_000, 1_700] {
            #expect(abs((GaugeMath.verticalSpeedAngle(v) + 90) + (GaugeMath.verticalSpeedAngle(-v) + 90)) < 1e-9)
        }
        #expect(GaugeMath.verticalSpeedAngle(9_000) == GaugeMath.verticalSpeedAngle(2_000))
        #expect(abs(GaugeMath.verticalSpeedAngle(1_000) - (-90 + 102)) < 1e-9)
    }

    @Test func standardRateTurnMeetsTheIndex() {
        #expect(GaugeMath.turnCoordinatorBank(3) == 20)
        #expect(GaugeMath.turnCoordinatorBank(-3) == -20)
    }
}

@Suite struct InstrumentSystemTests {
    @Test func levelTrimReadsTruthInStandardAtmosphere() {
        let model = FlightModel()
        let env = FlightEnvironment()
        let trim = model.trimLevel(trueAirspeed: 100 * Units.knotsToMps, altitude: 3_000 * Units.feetToMetres, environment: env)
        var sys = InstrumentSystem()
        var s = trim.state
        for _ in 0..<(120 * 10) {
            let out = model.outputs(s, inputs: trim.inputs, environment: env)
            sys.update(state: s, outputs: out, environment: env, inputs: trim.inputs, rpm: 2_300, dt: 1.0 / 120)
            s = model.step(s, inputs: trim.inputs, environment: env)
        }
        let d = sys.data
        let casKt = model.outputs(s, inputs: trim.inputs, environment: env).calibratedAirspeed / Units.knotsToMps
        #expect(abs(d.indicatedAltitudeFt - s.altitude / Units.feetToMetres) < 5)
        #expect(abs(d.indicatedAirspeedKt - casKt) < 0.5)
        #expect(abs(d.verticalSpeedFpm) < 60)
        #expect(abs(d.rollDeg) < 1 && abs(d.slipBall) < 0.1)
        #expect(abs(d.turnRateDegPerSec) < 0.2)
    }

    @Test func kollsmanSettingShiftsAboutAThousandFeetPerInch() {
        let model = FlightModel()
        let env = FlightEnvironment()
        let trim = model.trimLevel(trueAirspeed: 90 * Units.knotsToMps, altitude: 1_000, environment: env)
        let out = model.outputs(trim.state, inputs: trim.inputs, environment: env)
        func read(_ k: Double) -> Double {
            var sys = InstrumentSystem(); sys.kollsmanInHg = k
            sys.update(state: trim.state, outputs: out, environment: env, inputs: trim.inputs, rpm: 0, dt: 0)
            return sys.data.indicatedAltitudeFt
        }
        let delta = read(30.92) - read(29.92)
        #expect(delta > 880 && delta < 1_000)  // ≈ 920–940 ft per inHg at low altitude
    }

    @Test func blockedStaticPortFreezesAltimeterAndZeroesVSI() {
        var scenario = InstrumentScenario(bankDeg: 0)
        scenario.targetPitchDeg = 8
        for _ in 0..<(120 * 5) { scenario.step() }
        var sys = scenario.system
        sys.staticBlocked = true
        let model = scenario.model, env = scenario.environment
        var s = scenario.state
        let u = scenario.inputs
        let frozenAt = sys.data.indicatedAltitudeFt
        for _ in 0..<(120 * 15) {
            let out = model.outputs(s, inputs: u, environment: env)
            sys.update(state: s, outputs: out, environment: env, inputs: u, rpm: 0, dt: 1.0 / 120)
            s = model.step(s, inputs: u, environment: env)
        }
        #expect(abs(sys.data.indicatedAltitudeFt - frozenAt) < 1)
        #expect(abs(sys.data.verticalSpeedFpm) < 5)
        #expect(abs(s.altitude / Units.feetToMetres - frozenAt) > 50)  // the aeroplane really moved
    }

    @Test func climbingTurnShowsCoordinatedPhysics() {
        let d = InstrumentScenario.climbingTurn(seconds: 25, bankDeg: 20)
        #expect(abs(d.rollDeg - 20) < 2)
        // Rate of turn = g tan(φ) / V.
        let expected = ISA.g0 * tan(d.rollDeg * .pi / 180) / (d.trueAirspeedKt * Units.knotsToMps) * 180 / .pi
        #expect(abs(d.turnRateDegPerSec - expected) < 0.35)
        #expect(d.verticalSpeedFpm > 0)
        #expect(d.rpm > 2_000 && d.rpm < 2_800)
    }

    @Test func vSpeedsMatchTheFlightModelStall() {
        let model = FlightModel()
        let vs1 = model.designStallSpeed(altitude: 0) / Units.knotsToMps
        let vso = model.designStallSpeed(altitude: 0, flaps: 1) / Units.knotsToMps
        #expect(abs(VSpeeds.sf1Trainer.vs1 - vs1) < 1.5, "vs1 \(vs1) vso \(vso)")
        #expect(abs(VSpeeds.sf1Trainer.vso - vso) < 1.5)
    }

    @Test func propellerSpeedRisesWithThrottleAndAirspeed() {
        let rho = ISA.seaLevelDensity
        let idle = PropellerRPM.rpm(throttle: 0, trueAirspeed: 0, density: rho)
        let staticFull = PropellerRPM.rpm(throttle: 1, trueAirspeed: 0, density: rho)
        let cruise = PropellerRPM.rpm(throttle: 1, trueAirspeed: 50, density: rho)
        #expect(idle > 500 && idle < 1_100)
        #expect(staticFull > 2_100 && staticFull < 2_600)
        #expect(cruise > staticFull)
    }
}

@Suite struct DrawingTests {
    @Test func strokeFontCoversInstrumentText() {
        for ch in "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ.-+/:°" {
            #expect(StrokeFont.supported.contains(ch), "missing glyph \(ch)")
            for poly in StrokeFont.glyph(ch) {
                for p in poly { #expect(p.x >= 0 && p.x <= 4 && p.y >= -1 && p.y <= 6) }
            }
        }
        #expect(StrokeFont.width(of: "1.5") < StrokeFont.width(of: "105"))
    }

    @Test func rasterizerCoverageIsExactForAnAlignedSquare() {
        var b = DrawBuilder(width: 10, height: 10)
        b.rect(2, 2, 6, 6, .white)          // y-up builder space
        let img = Raster2D.render(b.list, width: 10, height: 10)
        let total = img.rgb.enumerated().filter { $0.offset % 3 == 0 }.reduce(Float(0)) { $0 + $1.element }
        #expect(abs(total - 16) < 1e-3)
        #expect(img.pixel(3, 5).0 == 1)     // inside (device rows flip: y 2…6 up = rows 4…8)
        #expect(img.pixel(3, 2).0 == 0)
    }

    @Test func halfPixelEdgeIsHalfCovered() {
        var b = DrawBuilder(width: 4, height: 4)
        b.rect(0, 0, 1.5, 4, .white)
        let img = Raster2D.render(b.list, width: 4, height: 4)
        #expect(abs(img.pixel(1, 1).0 - 0.5) < 1e-3)
    }

    @Test func clipCircleLimitsCoverage() {
        var b = DrawBuilder(width: 100, height: 100)
        b.pushClipCircle(Point2(50, 50), 30)
        b.rect(0, 0, 100, 100, .white)
        b.popClip()
        let img = Raster2D.render(b.list, width: 100, height: 100)
        let total = img.rgb.enumerated().filter { $0.offset % 3 == 0 }.reduce(Float(0)) { $0 + $1.element }
        #expect(abs(Double(total) - Double.pi * 900) < 30)
        #expect(img.pixel(2, 2).0 == 0)
    }

    @Test func overlappingStrokeSegmentsDoNotDoubleBlend() {
        var b = DrawBuilder(width: 40, height: 40)
        b.stroke([Point2(5, 20), Point2(20, 20), Point2(35, 20)], width: 6, RGBA(1, 1, 1, 0.5))
        let img = Raster2D.render(b.list, width: 40, height: 40)
        #expect(abs(img.pixel(20, 20).0 - 0.5) < 1e-3)   // joint pixel: union, not 0.75
    }

    @Test func panelsRenderDeterministicallyAndAreNotBlank() {
        let d = InstrumentScenario.climbingTurn(seconds: 5)
        let six = Raster2D.render(SteamGauges.sixPack(d), width: 300, height: 200)
        let pfd = Raster2D.render(PFD.draw(d), width: 320, height: 200)
        #expect(six.hash == Raster2D.render(SteamGauges.sixPack(d), width: 300, height: 200).hash)
        for img in [six, pfd] {
            let lum = img.rgb.reduce(Float(0), +) / Float(img.rgb.count)
            #expect(lum > 0.08 && lum < 0.8)
        }
        // The PFD sky is blue at the top centre and the ground brown at the bottom corner.
        let sky = pfd.pixel(160, 30), ground = pfd.pixel(310, 195)
        #expect(sky.2 > sky.0 + 0.2)
        #expect(ground.0 > ground.2 + 0.15)
    }
}
