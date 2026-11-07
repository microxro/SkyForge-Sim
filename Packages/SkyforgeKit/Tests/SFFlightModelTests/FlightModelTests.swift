import Testing
import Foundation
import SFMath
@testable import SFFlightModel

@Suite struct FlightModelTests {
    let model = FlightModel()
    let altitude = 3_000 * Units.feetToMetres
    let tas = 100 * Units.knotsToMps

    @Test func trimAt100KtasLevelFlight() {
        let trim = model.trimLevel(trueAirspeed: tas, altitude: altitude)
        #expect(trim.converged)
        #expect(trim.inputs.throttle > 0.2 && trim.inputs.throttle < 0.95)
        #expect(abs(trim.alpha) < 6 * Units.degToRad)
        // Hold trim for 10 s: vertical speed must stay within 50 ft/min.
        var s = trim.state
        let env = FlightEnvironment()
        var worstVS = 0.0
        for _ in 0..<1200 {
            s = model.step(s, inputs: trim.inputs, environment: env)
            worstVS = max(worstVS, abs(s.velocityNED.z) / Units.fpmToMps)
        }
        #expect(worstVS < 50, "worst vertical speed \(worstVS) ft/min")
    }

    @Test func stallSpeedMatchesDesign() {
        // Find the lowest speed at which level trim is still possible below the stall angle.
        let design = model.designStallSpeed(altitude: altitude)
        var lowest = tas
        var v = tas
        var previous: FlightModel.TrimResult?
        while v > 15 {
            let t = model.trimLevel(trueAirspeed: v, altitude: altitude, warmStart: previous)
            previous = t
            guard t.converged, t.alpha < model.config.stallAlpha + 0.05 else { break }
            let out = model.outputs(t.state, inputs: t.inputs, environment: FlightEnvironment())
            if out.stalled { break }
            lowest = v
            v -= 0.25
        }
        let diffKt = abs(lowest - design) / Units.knotsToMps
        #expect(diffKt < 3, "trim stall \(lowest / Units.knotsToMps) kt vs design \(design / Units.knotsToMps) kt")
    }

    @Test func energyConservedWithoutDragOrMoments() {
        var cfg = AircraftConfig.sf1Trainer
        var a = AeroCoefficients()
        a.cD0 = 0; a.cDFlap = 0; a.oswald = 1e12
        a.cYBeta = 0; a.cYRudder = 0
        a.cm0 = 0; a.cmAlpha = 0; a.cmQ = 0; a.cmElevator = 0; a.cmFlap = 0; a.cLQ = 0; a.cLElevator = 0
        a.clBeta = 0; a.clP = 0; a.clR = 0; a.clAileron = 0; a.clRudder = 0
        a.cnBeta = 0; a.cnP = 0; a.cnR = 0; a.cnAileron = 0; a.cnRudder = 0
        cfg.aero = a
        let m = FlightModel(config: cfg)
        var s = AircraftState(positionNED: SIMD3(0, 0, -2_000), velocityBody: SIMD3(50, 0, 3),
                              attitude: Quaternion(roll: 0.2, pitch: 0.05, yaw: 0.3), bodyRates: .zero)
        let env = FlightEnvironment()
        func energy(_ s: AircraftState) -> Double {
            let v = length(s.velocityBody)
            return 0.5 * v * v + 9.806_65 * s.altitude
        }
        let e0 = energy(s)
        for _ in 0..<(60 * 120) { s = m.step(s, inputs: ControlInputs(), environment: env) }
        let drift = abs(energy(s) - e0) / e0
        #expect(drift < 0.001, "energy drift \(drift)")
    }

    @Test func staticStabilitySigns() {
        let a = model.config.aero
        #expect(a.cmAlpha < 0)
        #expect(a.cnBeta > 0)
        #expect(a.clBeta < 0)
        #expect(a.clP < 0 && a.cmQ < 0 && a.cnR < 0)
    }

    func recordedRun(seconds: Int, seed: UInt64) -> (AircraftState, UInt64) {
        let trim = model.trimLevel(trueAirspeed: tas, altitude: altitude)
        var s = trim.state
        var rng = Xoshiro256(seed: seed)
        var inp = trim.inputs
        let env = FlightEnvironment(windNED: SIMD3(3, -2, 0))
        var h = FNV1a()
        for i in 0..<(seconds * 120) {
            if i % 60 == 0 {
                inp.elevator = clamp(trim.inputs.elevator + rng.range(-0.08, 0.08), -1, 1)
                inp.aileron = rng.range(-0.15, 0.15)
                inp.rudder = rng.range(-0.1, 0.1)
            }
            s = model.step(s, inputs: inp, environment: env)
            if i % 120 == 0 { s.hash(into: &h) }
        }
        s.hash(into: &h)
        return (s, h.value)
    }

    @Test func determinismOverTenMinutes() {
        let a = recordedRun(seconds: 600, seed: 99)
        let b = recordedRun(seconds: 600, seed: 99)
        #expect(a.1 == b.1)
        #expect(a.0.isFinite)
    }

    @Test func fuzzedRunStaysFinite() {
        // 1 hour of simulated time with random (including extreme and NaN) inputs.
        let seconds = ProcessInfo.processInfo.environment["SKYFORGE_FUZZ_SECONDS"].flatMap(Double.init) ?? 3600
        var s = model.trimLevel(trueAirspeed: tas, altitude: altitude).state
        var rng = Xoshiro256(seed: 2026)
        var inp = ControlInputs()
        let env = FlightEnvironment(windNED: SIMD3(8, 4, 1))
        for i in 0..<Int(seconds * 120) {
            if i % 30 == 0 {
                inp = ControlInputs(elevator: rng.range(-2, 2), aileron: rng.range(-2, 2), rudder: rng.range(-2, 2),
                                    throttle: rng.range(-1, 2), flaps: rng.range(0, 1), brakes: rng.unit())
                if rng.unit() < 0.01 { inp.elevator = .nan }
            }
            s = model.step(s, inputs: inp, environment: env)
            if !s.isFinite { Issue.record("non-finite state at step \(i)"); return }
        }
        #expect(s.isFinite)
    }

    @Test func restsOnGround() {
        // Placed just above the runway with engine off and brakes on, the aircraft settles and stays put.
        var s = AircraftState(positionNED: SIMD3(0, 0, -1.25), velocityBody: .zero,
                              attitude: .identity, bodyRates: .zero)
        let env = FlightEnvironment()
        let inp = ControlInputs(brakes: 1)
        for _ in 0..<(10 * 120) { s = model.step(s, inputs: inp, environment: env) }
        #expect(abs(s.velocityNED.z) < 0.05)
        #expect(length(SIMD3(s.positionNED.x, s.positionNED.y, 0)) < 0.5)
        #expect(s.altitude > 1.0 && s.altitude < 1.3)
        #expect(model.outputs(s, inputs: inp, environment: env).weightOnWheels)
    }

    @Test func takeoffRoll() {
        // Full throttle from rest: lifts off within a plausible distance for a light trainer.
        var s = AircraftState(positionNED: SIMD3(0, 0, -1.20), velocityBody: .zero, attitude: .identity, bodyRates: .zero)
        let env = FlightEnvironment()
        var inp = ControlInputs(throttle: 1)
        var liftoff: Double?
        for i in 0..<(60 * 120) {
            let out = model.outputs(s, inputs: inp, environment: env)
            inp.elevator = out.calibratedAirspeed > 28 ? 0.35 : 0
            s = model.step(s, inputs: inp, environment: env)
            if s.altitude > 6 { liftoff = s.positionNED.x; _ = i; break }
        }
        #expect(liftoff != nil)
        if let d = liftoff { #expect(d > 150 && d < 700, "liftoff distance \(d) m") }
    }
}

@Suite struct ControlSenseTests {
    let model = FlightModel()
    func response(_ inp: ControlInputs) -> SIMD3<Double> {
        let trim = model.trimLevel(trueAirspeed: 50, altitude: 1000)
        var i = trim.inputs
        i.elevator += inp.elevator; i.aileron = inp.aileron; i.rudder = inp.rudder
        var s = trim.state
        for _ in 0..<60 { s = model.step(s, inputs: i, environment: FlightEnvironment()) }
        return s.bodyRates
    }
    @Test func stickBackPitchesUp() { #expect(response(ControlInputs(elevator: 0.3)).y > 0.05) }
    @Test func stickRightRollsRight() { #expect(response(ControlInputs(aileron: 0.3)).x > 0.05) }
    @Test func rightPedalYawsRight() { #expect(response(ControlInputs(rudder: 0.3)).z > 0.02) }
}
