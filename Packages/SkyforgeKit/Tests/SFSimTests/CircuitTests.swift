import Testing
import SFMath
@testable import SFSim
@testable import SFSystems
import SFFlightModel

@Suite struct CircuitTests {
    @Test func pidAntiWindup() {
        var p = PID(kp: 1, ki: 1, outputMin: -1, outputMax: 1, integralLimit: 100)
        for _ in 0..<1000 { _ = p.update(error: 10, dt: 0.01) }
        #expect(p.integral < 1.5)   // saturated: integration halted
    }

    @Test func scriptedCircuitLandsOnRunway() {
        let r = ScriptedCircuit().fly()
        let phases = r.phaseLog.map { "\($0.phase.rawValue)@\(Int($0.time))s" }.joined(separator: " ")
        #expect(r.finite)
        #expect(r.finalPhase == .stopped, "phases: \(phases)")
        #expect(r.maxAltitude > 250, "phases: \(phases)")
        if let vs = r.touchdownVerticalSpeedFPM { #expect(vs > -600, "touchdown \(vs) fpm") }
        if let stop = r.stopPosition {
            #expect(stop.x > 0 && stop.x < 1_500, "stopped at \(stop)")
            #expect(abs(stop.y) < 15, "stopped at \(stop)")
        }
        #expect(r.maxBankDegrees < 35)
    }
}

@Suite struct CrosswindCircuitTests {
    @Test func landsWithEightKnotCrosswind() {
        // Wind from 270° at 8 kt blows toward east (+y).
        var env = SFFlightModel.FlightEnvironment()
        env.windNED = SIMD3(0, 8 * Units.knotsToMps, 0)
        let r = ScriptedCircuit(environment: env).fly()
        let phases = r.phaseLog.map { "\($0.phase.rawValue)@\(Int($0.time))s" }.joined(separator: " ")
        #expect(r.finalPhase == .stopped, "phases: \(phases)")
        if let vs = r.touchdownVerticalSpeedFPM { #expect(vs > -600, "touchdown \(vs) fpm") }
        if let stop = r.stopPosition { #expect(stop.x > 0 && stop.x < 1_500 && abs(stop.y) < 15, "stopped at \(stop)") }
    }
}
