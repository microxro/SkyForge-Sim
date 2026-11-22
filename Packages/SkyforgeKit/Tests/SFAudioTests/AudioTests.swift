// SKYFORGE — Apache-2.0
import Testing
import Foundation
import SFMath
@testable import SFAudio
import SFFlightModel
import SFWeather

@Suite struct AudioModelTests {
    static func state(sinkMps: Double = 0) -> AircraftState {
        // Attitude identity: body frame == NED, so velocityBody.z is the sink rate.
        AircraftState(positionNED: SIMD3(0, 0, -100), velocityBody: SIMD3(40, 0, sinkMps), attitude: Quaternion.identity, bodyRates: .zero)
    }
    static func outputs(wow: Bool = false, tas: Double = 40, alpha: Double = 0.05, stalled: Bool = false) -> FlightOutputs {
        var o = FlightOutputs(); o.weightOnWheels = wow; o.trueAirspeed = tas; o.alpha = alpha; o.stalled = stalled; return o
    }

    @Test func rpmRisesWithThrottleAndStaysAboveIdle() {
        let idle = AudioModel.targetRPM(throttle: 0, trueAirspeed: 0, maxRPM: 2_700)
        let full = AudioModel.targetRPM(throttle: 1, trueAirspeed: 60, maxRPM: 2_700)
        #expect(idle == AudioModel.idleRPM)
        #expect(full > idle && full <= 2_700)
        #expect(AudioModel.targetRPM(throttle: 0.5, trueAirspeed: 30, maxRPM: 2_700) < full)
    }

    @Test func rpmLagsThenConverges() {
        var m = AudioModel()
        var c = ControlInputs(); c.throttle = 1
        _ = m.update(dt: 0.05, time: 0, state: Self.state(), outputs: Self.outputs(wow: true, tas: 0), inputs: c, weather: .clear)
        let early = m.params.engineRPM
        for i in 1..<400 { _ = m.update(dt: 0.05, time: Double(i) * 0.05, state: Self.state(), outputs: Self.outputs(wow: true, tas: 0), inputs: c, weather: .clear) }
        #expect(early < m.params.engineRPM)
        #expect(abs(m.params.engineRPM - AudioModel.targetRPM(throttle: 1, trueAirspeed: 0, maxRPM: 2_700)) < 5)
    }

    @Test func touchdownFiresOnceWithSinkScaledIntensity() {
        func land(sink: Double) -> [AudioEvent] {
            var m = AudioModel()
            let c = ControlInputs()
            _ = m.update(dt: 0.02, time: 0, state: Self.state(sinkMps: sink), outputs: Self.outputs(wow: false), inputs: c, weather: .clear)
            let hit = m.update(dt: 0.02, time: 0.02, state: Self.state(), outputs: Self.outputs(wow: true), inputs: c, weather: .clear)
            let after = m.update(dt: 0.02, time: 0.04, state: Self.state(), outputs: Self.outputs(wow: true), inputs: c, weather: .clear)
            #expect(after.isEmpty)
            return hit
        }
        guard case .touchdown(let soft)? = land(sink: 0.3).first, case .touchdown(let hard)? = land(sink: 3.5).first else {
            Issue.record("no touchdown event"); return
        }
        #expect(soft < hard)
        #expect(hard == 1)
    }

    @Test func stallHornFromAngleOfAttack() {
        var m = AudioModel()
        _ = m.update(dt: 0.02, time: 0, state: Self.state(), outputs: Self.outputs(alpha: 0.05), inputs: ControlInputs(), weather: .clear)
        #expect(!m.params.stallHorn)
        _ = m.update(dt: 0.02, time: 0.02, state: Self.state(), outputs: Self.outputs(alpha: AircraftConfig.sf1Trainer.stallAlpha), inputs: ControlInputs(), weather: .clear)
        #expect(m.params.stallHorn)
        _ = m.update(dt: 0.02, time: 0.04, state: Self.state(), outputs: Self.outputs(wow: true, alpha: 0.5), inputs: ControlInputs(), weather: .clear)
        #expect(!m.params.stallHorn)
    }

    @Test func windGrowsWithAirspeedAndRainFollowsWeather() throws {
        #expect(AudioModel.windGain(trueAirspeed: 20, openness: 0.2) < AudioModel.windGain(trueAirspeed: 60, openness: 0.2))
        #expect(AudioModel.windGain(trueAirspeed: 200, openness: 1) <= 1)
        let rain = WeatherEffects(metar: try METARParser.parse("KSEA 221656Z 18010KT 1SM +RA OVC008 10/08 A2990"))
        var m = AudioModel()
        _ = m.update(dt: 0.02, time: 0, state: Self.state(), outputs: Self.outputs(), inputs: ControlInputs(), weather: rain)
        #expect(m.params.rainGain > 0.8)
    }

    @Test func flapMotorAndThunderEvents() throws {
        var m = AudioModel()
        var c = ControlInputs(); c.flaps = 0.5
        let e = m.update(dt: 0.02, time: 0, state: Self.state(), outputs: Self.outputs(), inputs: c, weather: .clear)
        #expect(e.contains(.flapMotor))
        let ts = WeatherEffects(metar: try METARParser.parse("KMCO 221656Z 18015G28KT 3SM +TSRA BKN025CB 27/23 A2992"))
        var thunder = 0
        for i in 0..<(60 * 50) {   // 60 s at 50 Hz
            for ev in m.update(dt: 0.02, time: Double(i) * 0.02, state: Self.state(), outputs: Self.outputs(), inputs: c, weather: ts) {
                if case .thunder = ev { thunder += 1 }
            }
        }
        #expect(thunder >= 1)
    }
}

@Suite struct ProceduralSynthTests {
    static func render(_ synth: inout ProceduralSynth, frames: Int, params: AudioParameters) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        out.withUnsafeMutableBufferPointer { synth.render($0.baseAddress!, frames: frames, params: params) }
        return out
    }
    static func rms(_ x: [Float]) -> Double { sqrt(x.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, x.count))) }

    @Test func silentWhenEverythingIsOff() {
        var s = ProceduralSynth()
        var p = AudioParameters(); p.cabinOpenness = 0
        let out = Self.render(&s, frames: 4_800, params: p)
        #expect(Self.rms(out) < 1e-3)
    }

    @Test func engineOutputIsBoundedFiniteAndLouderWithThrottle() {
        func level(throttle: Double) -> Double {
            var s = ProceduralSynth()
            var p = AudioParameters()
            p.engineRPM = AudioModel.targetRPM(throttle: throttle, trueAirspeed: 0, maxRPM: 2_700)
            p.engineLoad = throttle; p.engineGain = 0.55 + 0.35 * throttle
            var all: [Float] = []
            for _ in 0..<20 { all += Self.render(&s, frames: 1_024, params: p) }
            #expect(all.allSatisfy { $0.isFinite && abs($0) <= 1 })
            return Self.rms(Array(all.suffix(8_192)))
        }
        #expect(level(throttle: 1) > level(throttle: 0))
        #expect(level(throttle: 0) > 0.01)
    }

    @Test func touchdownThumpDecays() {
        var s = ProceduralSynth()
        var p = AudioParameters(); p.cabinOpenness = 1
        s.trigger(.touchdown(intensity: 1))
        let first = Self.render(&s, frames: 4_800, params: p)
        let later = Self.render(&s, frames: 48_000, params: p) + Self.render(&s, frames: 4_800, params: p)
        #expect(Self.rms(first) > 0.05)
        #expect(Self.rms(Array(later.suffix(4_800))) < 1e-3)
    }

    @Test func stallHornIsAudible() {
        var s = ProceduralSynth()
        var p = AudioParameters(); p.stallHorn = true; p.cabinOpenness = 1
        #expect(Self.rms(Self.render(&s, frames: 4_800, params: p)) > 0.03)
    }
}
