import Testing
import Foundation
import SFMath
@testable import SFFlightModel

@Suite struct FloatsSpinCrosswindTests {

    // MARK: Water surface

    @Test func waterSlowsTheRolloutMoreThanPaved() {
        func rollout(_ surface: GroundSurface) -> Double {
            let m = FlightModel()
            var s = AircraftState(positionNED: SIMD3(0, 0, -1.2), velocityBody: SIMD3(25, 0, 0), attitude: .identity, bodyRates: .zero)
            var env = FlightEnvironment()
            env.surface = surface
            for _ in 0..<(60 * 120) { s = m.step(s, inputs: ControlInputs(), environment: env) }
            return s.positionNED.x
        }
        #expect(rollout(.water) < rollout(.paved))
        #expect(GroundSurface.water.tractionScale < GroundSurface.paved.tractionScale)
    }

    // MARK: Runway wind components

    @Test func headwindAndTailwindFollowTheRunway() {
        let head = RunwayWind.components(airmassNED: SIMD3(-5, 0, 0), runwayHeadingRad: 0)
        #expect(abs(head.headwind - 5) < 1e-9)
        #expect(abs(head.crosswind) < 1e-9)
        let tail = RunwayWind.components(airmassNED: SIMD3(5, 0, 0), runwayHeadingRad: 0)
        #expect(abs(tail.headwind + 5) < 1e-9, "air moving down the runway is a tailwind")
    }

    @Test func crosswindIsPositiveFromTheRight() {
        // Runway heading north: east is the right. Air moving west means wind from the east (from the right).
        let fromRight = RunwayWind.components(airmassNED: SIMD3(0, -5, 0), runwayHeadingRad: 0)
        #expect(abs(fromRight.crosswind - 5) < 1e-9)
        // Runway heading east: south is the right. Air moving north means wind from the south (from the right).
        let east = RunwayWind.components(airmassNED: SIMD3(5, 0, 0), runwayHeadingRad: .pi / 2)
        #expect(abs(east.crosswind - 5) < 1e-9)
        #expect(abs(east.headwind) < 1e-9)
    }

    @Test func crosswindLimitRejectsNonFiniteLimits() {
        let w = RunwayWind.components(airmassNED: SIMD3(0, -5, 0), runwayHeadingRad: 0)
        #expect(w.withinCrosswindLimit(10))
        #expect(!w.withinCrosswindLimit(3))
        #expect(!w.withinCrosswindLimit(.nan))
    }

    // MARK: Spin assessment

    @Test func stalledWithSustainedYawIsASpin() {
        let right = SpinAssessment.assess(stalled: true, bodyRates: SIMD3(0.4, 0, 0.6))
        #expect(right.inSpin)
        #expect(right.direction == 1)
        #expect(right.recoveryRudder == -1, "opposite rudder stops a right spin")
        #expect(right.recoveryElevator == -1, "forward elevator unstalls")

        let left = SpinAssessment.assess(stalled: true, bodyRates: SIMD3(-0.3, 0, -0.5))
        #expect(left.inSpin)
        #expect(left.direction == -1)
        #expect(left.recoveryRudder == 1)
    }

    @Test func noSpinWithoutAStall() {
        let a = SpinAssessment.assess(stalled: false, bodyRates: SIMD3(0.4, 0, 0.6))
        #expect(!a.inSpin)
        #expect(a.recoveryRudder == 0 && a.recoveryElevator == 0)
    }

    @Test func noSpinAtSmallRatesOrNonFiniteRates() {
        #expect(!SpinAssessment.assess(stalled: true, bodyRates: SIMD3(0.1, 0, 0.1)).inSpin)
        #expect(!SpinAssessment.assess(stalled: true, bodyRates: SIMD3(.nan, 0, 0.6)).inSpin)
    }
}
