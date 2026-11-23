import Testing
import Foundation
import SFMath
import SFFlightModel
@testable import SFGameplay

/// Headless timing of the fixed-step sim loop. Numbers print to the CI log so changes can be compared run to run.
/// The gate is deliberately loose (2 ms per 120 Hz step, against an 8.3 ms frame budget): it catches a large
/// regression without making CI flaky on shared runners.
@Suite struct SimStepBenchmarkTests {
    static let budgetPerStepSeconds = 0.002

    @Test func gameplayStepStaysWithinBudget() {
        let world = FlatWorld()
        var s = GameplaySession(world: world, aircraft: AircraftCatalog.sf1Trainer)
        let steps = 120 * 10
        // Warm up so first-call allocations do not count.
        for _ in 0..<120 {
            var c = PilotControls()
            c.flight.throttle = 1
            c.flight.elevator = s.trueAirspeed >= AircraftCatalog.sf1Trainer.rotateSpeed ? 0.15 : 0
            s.step(c)
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<steps {
                var c = PilotControls()
                c.flight.throttle = 1
                c.flight.elevator = s.trueAirspeed >= AircraftCatalog.sf1Trainer.rotateSpeed ? 0.15 : 0
                s.step(c)
            }
        }
        let parts = elapsed.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let perStep = seconds / Double(steps)
        print("BENCH gameplay.step sf1 \(String(format: "%.1f", perStep * 1e6)) us/step over \(steps) steps")
        #expect(s.state.isFinite, "state went non-finite during the benchmark")
        #expect(perStep < Self.budgetPerStepSeconds, "gameplay step took \(perStep * 1e3) ms, budget is 2 ms")
    }
}
