import Testing
import Foundation
import SFMath
@testable import SFFlightModel

@Suite struct CivilOperationsTests {

    // MARK: Engine failure and relight

    @Test func failingAnEngineSetsItsBitInTheMask() {
        var ops = EngineOperations(engineCount: 2)
        #expect(ops.failureMask == 0)
        #expect(ops.fail(1))
        #expect(ops.failureMask == 0b10)
        #expect(ops.runningCount == 1)
        #expect(!ops.fail(1), "a failed engine cannot fail again")
        #expect(!ops.fail(5), "an out-of-range index is ignored")
    }

    @Test func relightIsRefusedBelowTheWindmillSpeed() {
        var ops = EngineOperations(engineCount: 1, relightTime: 10, minRelightSpeed: 55)
        ops.fail(0)
        #expect(!ops.requestRestart(0, trueAirspeed: 40))
        #expect(ops.states[0] == .failed)
        #expect(ops.requestRestart(0, trueAirspeed: 70))
        #expect(ops.failureMask == 1, "a relighting engine still produces no thrust")
    }

    @Test func relightCompletesAfterTheRelightTime() {
        var ops = EngineOperations(engineCount: 1, relightTime: 10, minRelightSpeed: 55)
        ops.fail(0)
        ops.requestRestart(0, trueAirspeed: 80)
        for _ in 0..<(9 * 120) { ops.update(dt: 1.0 / 120, trueAirspeed: 80) }
        #expect(ops.states[0] != .running, "relight finished early")
        for _ in 0..<(2 * 120) { ops.update(dt: 1.0 / 120, trueAirspeed: 80) }
        #expect(ops.states[0] == .running)
        #expect(ops.failureMask == 0)
    }

    @Test func slowingDownAbortsARelight() {
        var ops = EngineOperations(engineCount: 1, relightTime: 10, minRelightSpeed: 55)
        ops.fail(0)
        ops.requestRestart(0, trueAirspeed: 80)
        ops.update(dt: 1, trueAirspeed: 30)
        #expect(ops.states[0] == .failed)
    }

    @Test func badEngineCountsAndStepsAreClamped() {
        let ops = EngineOperations(engineCount: -3)
        #expect(ops.engineCount == 0)
        var two = EngineOperations(engineCount: 2)
        two.fail(0)
        two.update(dt: .nan, trueAirspeed: 80)
        #expect(two.states[0] == .failed, "a non-finite time step must not change state")
    }

    // MARK: Weight and balance

    @Test func loadsSetTotalMassAndCGArm() {
        let wb = WeightAndBalance(emptyMass: 1_000, emptyCGArm: 0, stations: [
            PayloadStation(name: "front", mass: 200, arm: 0.5),
            PayloadStation(name: "rear", mass: 200, arm: -0.5),
        ])
        #expect(wb.totalMass == 1_400)
        #expect(abs(wb.cgArm) < 1e-12, "symmetric loads leave the CG where it was")
    }

    @Test func aftLoadMovesCGAftAndReducesPitchStability() {
        let base = AircraftConfig.sf1Trainer
        let wb = WeightAndBalance(emptyMass: base.mass, stations: [PayloadStation(name: "bags", mass: 150, arm: -0.6)],
                                  forwardLimit: 0.12, aftLimit: -0.18, chord: base.chord)
        #expect(wb.cgArm < 0, "a rear load moves the CG aft")
        let loaded = wb.applied(to: base)
        #expect(loaded.mass == base.mass + 150)
        #expect(loaded.inertia.x > base.inertia.x, "more mass means more roll inertia")
        #expect(loaded.aero.cmAlpha > base.aero.cmAlpha, "cmAlpha is negative, so a less negative value is less stable")
    }

    @Test func forwardLoadIncreasesPitchStability() {
        let base = AircraftConfig.sf1Trainer
        let wb = WeightAndBalance(emptyMass: base.mass, stations: [PayloadStation(name: "front", mass: 100, arm: 0.8)],
                                  chord: base.chord)
        #expect(wb.cgArm > 0)
        #expect(wb.applied(to: base).aero.cmAlpha < base.aero.cmAlpha)
    }

    @Test func cgEnvelopeStatusFlagsOverrunsAndIsWithinWhenInside() {
        let aft = WeightAndBalance(emptyMass: 1_000, stations: [PayloadStation(name: "x", mass: 400, arm: -1.0)],
                                   forwardLimit: 0.1, aftLimit: -0.2)
        #expect(aft.status == .aftOfLimit)
        let fwd = WeightAndBalance(emptyMass: 1_000, stations: [PayloadStation(name: "x", mass: 400, arm: 1.0)],
                                   forwardLimit: 0.1, aftLimit: -0.2)
        #expect(fwd.status == .forwardOfLimit)
        #expect(WeightAndBalance(emptyMass: 1_000).status == .withinEnvelope)
    }

    @Test func heavierLoadRaisesStallSpeed() {
        let base = AircraftConfig.sf1Trainer
        let heavy = WeightAndBalance(emptyMass: base.mass, stations: [PayloadStation(name: "cargo", mass: 300, arm: 0)])
        let lightStall = FlightModel(config: base).designStallSpeed(altitude: 0)
        let heavyStall = FlightModel(config: heavy.applied(to: base)).designStallSpeed(altitude: 0)
        #expect(heavyStall > lightStall)
    }

    @Test func negativeStationMassIsClampedToZero() {
        let s = PayloadStation(name: "bad", mass: -50, arm: .nan)
        #expect(s.mass == 0)
        #expect(s.arm == 0)
    }

    // MARK: Soft field and bush strips

    @Test func softFieldLengthensTheRollout() {
        func rollout(_ surface: GroundSurface) -> Double {
            let m = FlightModel()
            var s = AircraftState(positionNED: SIMD3(0, 0, -1.2), velocityBody: SIMD3(25, 0, 0), attitude: .identity, bodyRates: .zero)
            var env = FlightEnvironment()
            env.surface = surface
            for _ in 0..<(60 * 120) { s = m.step(s, inputs: ControlInputs(), environment: env) }
            return s.positionNED.x
        }
        #expect(rollout(.softField) < rollout(.paved), "soft ground should slow the aircraft sooner")
        #expect(rollout(.mud) < rollout(.softField))
    }

    @Test func pavedSurfaceAddsNoResistance() {
        #expect(GroundSurface.paved.rollingCoefficient == 0)
        #expect(GroundSurface.paved.tractionScale == 1)
        for s in GroundSurface.allCases {
            #expect(s.rollingCoefficient >= 0)
            #expect(s.tractionScale > 0 && s.tractionScale <= 1)
        }
    }
}
