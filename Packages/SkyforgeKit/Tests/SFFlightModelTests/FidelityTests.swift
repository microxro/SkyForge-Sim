import Testing
import Foundation
import SFMath
import SFAtmosphere
@testable import SFFlightModel

@Suite struct FidelityTests {
    let kt = Units.knotsToMps
    let ft = Units.feetToMetres

    @Test func catalogAircraftTrimInCruise() {
        let cases: [(AircraftConfig, Double, Double)] = [
            (.sf2Cruiser, 140, 5_000), (.sf3Twin, 150, 5_000), (.sf5Jet, 300, 10_000), (.sf9Fighter, 450, 10_000),
        ]
        for (cfg, knots, alt) in cases {
            let m = FlightModel(config: cfg)
            let t = m.trimLevel(trueAirspeed: knots * kt, altitude: alt * ft)
            #expect(t.converged, "\(cfg.name) failed to trim")
            #expect(t.inputs.throttle > 0.05 && t.inputs.throttle < 0.95, "\(cfg.name) throttle \(t.inputs.throttle)")
            var s = t.state
            for _ in 0..<(20 * 120) { s = m.step(s, inputs: t.inputs, environment: FlightEnvironment()) }
            #expect(abs(s.velocityNED.z) / Units.fpmToMps < 100, "\(cfg.name) drifted off trim")
        }
    }

    @Test func fighterTrimsSupersonicWithAfterburnerHeadroom() {
        let m = FlightModel(config: .sf9Fighter)
        let a = ISA.state(geometricAltitude: 36_000 * ft).speedOfSound
        let t = m.trimLevel(trueAirspeed: 1.2 * a, altitude: 36_000 * ft)
        #expect(t.converged)
        let out = m.outputs(t.state, inputs: t.inputs, environment: FlightEnvironment())
        #expect(abs(out.mach - 1.2) < 0.01)
    }

    @Test func waveDragRaisesDragAcrossMachOne() {
        let sched = AircraftConfig.sf9Fighter.mach
        #expect(sched.evaluate(0.5).waveDrag == 0)
        #expect(sched.evaluate(1.0).waveDrag > 0.02)
        #expect(sched.evaluate(0.95).waveDrag > sched.evaluate(0.85).waveDrag)
        #expect(MachSchedule.incompressible.evaluate(0.9).liftSlope == 1)
    }

    @Test func engineOutYawsTowardDeadEngine() {
        let m = FlightModel(config: .sf3Twin)
        var t = m.trimLevel(trueAirspeed: 90 * kt, altitude: 3_000 * ft)
        t.inputs.throttle = 1
        t.inputs.engineFailureMask = 1   // right engine
        var s = t.state
        for _ in 0..<240 { s = m.step(s, inputs: t.inputs, environment: FlightEnvironment()) }
        #expect(s.bodyRates.z > 0.05, "right-engine failure must yaw right")
        t.inputs.engineFailureMask = 2   // left engine
        s = t.state
        for _ in 0..<240 { s = m.step(s, inputs: t.inputs, environment: FlightEnvironment()) }
        #expect(s.bodyRates.z < -0.05)
    }

    @Test func gearRetractionReducesDrag() {
        let m = FlightModel(config: .sf2Cruiser)
        let s = AircraftState(positionNED: SIMD3(0, 0, -1_500), velocityBody: SIMD3(60, 0, 0), attitude: .identity, bodyRates: .zero)
        let down = m.outputs(s, inputs: ControlInputs(throttle: 0.5, gear: 1), environment: FlightEnvironment())
        let up = m.outputs(s, inputs: ControlInputs(throttle: 0.5, gear: 0), environment: FlightEnvironment())
        #expect(down.forceBody.x < up.forceBody.x)
    }

    @Test func turbofanThrustFallsWithAltitudeAndAfterburnerAddsThrust() {
        let p = AircraftConfig.sf9Fighter.propulsion!
        let sl = p.engineOutput(throttle: 0.8, density: ISA.seaLevelDensity, altitude: 0, mach: 0.3, axialSpeed: 100).thrust
        let hi = p.engineOutput(throttle: 0.8, density: ISA.seaLevelDensity * 0.3, altitude: 11_000, mach: 0.3, axialSpeed: 100).thrust
        let ab = p.engineOutput(throttle: 1.0, density: ISA.seaLevelDensity, altitude: 0, mach: 0.3, axialSpeed: 100).thrust
        #expect(hi < 0.5 * sl)
        #expect(ab > 1.3 * sl)
    }

    @Test func controlInputsDecodeOldRecordings() throws {
        let json = #"{"elevator":0.2,"aileron":0,"rudder":0,"throttle":1,"flaps":0,"brakes":0,"elevatorTrim":0}"#
        let c = try JSONDecoder().decode(ControlInputs.self, from: Data(json.utf8))
        #expect(c.gear == 1 && c.speedbrake == 0 && c.engineFailureMask == 0 && c.throttle == 1)
    }

    @Test func turbulenceIsDeterministicAndScaled() {
        var a = DrydenTurbulence(seed: 7, severity: .moderate, wind20: 5)
        var b = DrydenTurbulence(seed: 7, severity: .moderate, wind20: 5)
        var sumSq = 0.0
        let n = 600 * 120
        for _ in 0..<n {
            let ga = a.step(dt: 1.0 / 120, heightAGL: 300, airspeed: 50, headingRad: 0.3)
            let gb = b.step(dt: 1.0 / 120, heightAGL: 300, airspeed: 50, headingRad: 0.3)
            #expect(ga == gb)
            sumSq += ga.z * ga.z
        }
        let rms = (sumSq / Double(n)).squareRoot()
        #expect(rms > 0.2 && rms < 1.2, "w rms \(rms)")
        var none = DrydenTurbulence(seed: 1, severity: .none)
        #expect(none.step(dt: 0.01, heightAGL: 100, airspeed: 50, headingRad: 0) == .zero)
    }

    @Test func engineSpoolApproachesCommand() {
        var e = EngineSpool.jet
        for _ in 0..<(10 * 120) { e.update(command: 1, dt: 1.0 / 120) }
        #expect(e.level > 0.95 && e.level <= 1)
        let mid = { () -> Double in var x = EngineSpool.jet; x.update(command: 1, dt: 0.5); return x.level }()
        #expect(mid > 0 && mid < 0.5)
    }

    @Test func wetRunwayLengthensBrakingStop() {
        func stopDistance(friction: Double) -> Double {
            let m = FlightModel()
            var s = AircraftState(positionNED: SIMD3(0, 0, -1.2), velocityBody: SIMD3(25, 0, 0), attitude: .identity, bodyRates: .zero)
            let env = FlightEnvironment(surfaceFriction: friction)
            for _ in 0..<(40 * 120) { s = m.step(s, inputs: ControlInputs(brakes: 1), environment: env) }
            return s.positionNED.x
        }
        #expect(stopDistance(friction: 0.4) > stopDistance(friction: 1.0))
    }

    @Test func turbulenceRejectsBadTimeSteps() {
        var t = DrydenTurbulence(seed: 3, severity: .light)
        #expect(t.step(dt: -0.01, heightAGL: 100, airspeed: 50, headingRad: 0) == .zero)
        #expect(t.step(dt: .nan, heightAGL: 100, airspeed: 50, headingRad: 0) == .zero)
    }

    @Test func degenerateConfigsStayFinite() {
        var cfg = AircraftConfig.sf2Cruiser
        cfg.propulsion?.staticThrustPerWatt = 0
        cfg.mach = MachSchedule(points: [.init(mach: 0, liftSlope: 0), .init(mach: 2, liftSlope: -1)])
        let m = FlightModel(config: cfg)
        var s = AircraftState(positionNED: SIMD3(0, 0, -1_500), velocityBody: SIMD3(60, 0, 3), attitude: .identity, bodyRates: .zero)
        for _ in 0..<600 { s = m.step(s, inputs: ControlInputs(throttle: 1), environment: FlightEnvironment()) }
        #expect(s.isFinite)
    }

    @Test func severityScalesLowLevelTurbulence() {
        func rms(_ sev: DrydenTurbulence.Severity) -> Double {
            var t = DrydenTurbulence(seed: 11, severity: sev, wind20: 5)
            var sum = 0.0
            let n = 600 * 120
            for _ in 0..<n { let g = t.step(dt: 1.0 / 120, heightAGL: 100, airspeed: 50, headingRad: 0); sum += g.z * g.z }
            return (sum / Double(n)).squareRoot()
        }
        #expect(rms(.severe) > rms(.light))
    }

    @Test func engineSpoolIgnoresBadDt() {
        var e = EngineSpool.jet
        e.update(command: 1, dt: .nan); e.update(command: 1, dt: -1)
        #expect(e.level == 0)
    }
}
