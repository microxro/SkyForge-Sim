import Testing
import Foundation
import SFMath
@testable import SFFlightModel

@Suite struct SpinAndScoopTests {

    // MARK: Spin aerodynamics

    @Test func yawReversalPushesAStalledAircraftFurtherIntoASpin() {
        var base = AircraftConfig.sf1Trainer
        base.stall.spinYawReversal = 0
        var reversed = base
        reversed.stall.spinYawReversal = 1.0
        // 25 degrees angle of attack is well past the stall break, with a 0.5 rad/s yaw rate.
        let s = AircraftState(positionNED: SIMD3(0, 0, -1_000), velocityBody: SIMD3(10, 0, 10 * tan(25 * Double.pi / 180)),
                              attitude: .identity, bodyRates: SIMD3(0, 0, 0.5))
        let env = FlightEnvironment()
        let m0 = FlightModel(config: base).forcesAndMoments(s, ControlInputs(), env).1
        let m1 = FlightModel(config: reversed).forcesAndMoments(s, ControlInputs(), env).1
        #expect(m1.z > m0.z, "reversed yaw damping must add yaw moment in the direction of the yaw rate")
    }

    @Test func yawReversalDoesNothingBeforeTheStall() {
        var base = AircraftConfig.sf1Trainer
        base.stall.spinYawReversal = 0
        var reversed = base
        reversed.stall.spinYawReversal = 1.0
        // 3 degrees: attached flow, sigma is near zero.
        let s = AircraftState(positionNED: SIMD3(0, 0, -1_000), velocityBody: SIMD3(60, 0, 60 * tan(3 * Double.pi / 180)),
                              attitude: .identity, bodyRates: SIMD3(0, 0, 0.5))
        let env = FlightEnvironment()
        let m0 = FlightModel(config: base).forcesAndMoments(s, ControlInputs(), env).1
        let m1 = FlightModel(config: reversed).forcesAndMoments(s, ControlInputs(), env).1
        #expect(abs(m1.z - m0.z) < 1e-3 * max(1, abs(m0.z)))
    }

    @Test func stallBehaviourWithoutTheNewKeyStillDecodes() throws {
        let old = #"{"autorotation":1.3,"wingDropGain":0.12,"noseDrop":0.1,"buffetStartMargin":0.07}"#
        let decoded = try JSONDecoder().decode(StallBehavior.self, from: Data(old.utf8))
        #expect(decoded.autorotation == 1.3)
        #expect(decoded.spinYawReversal == 0)
    }

    // MARK: Water scooping

    @Test func scoopTakesWaterOnlyWhileSkimmingInTheBand() {
        var scoop = WaterScoop()
        scoop.doorOpen = true
        #expect(scoop.isScooping(speed: 35, heightAboveWater: 0.5, onWater: true))
        #expect(!scoop.isScooping(speed: 20, heightAboveWater: 0.5, onWater: true), "too slow to plane")
        #expect(!scoop.isScooping(speed: 50, heightAboveWater: 0.5, onWater: true), "too fast for the scoop")
        #expect(!scoop.isScooping(speed: 35, heightAboveWater: 5, onWater: true), "hull is too high")
        #expect(!scoop.isScooping(speed: 35, heightAboveWater: 0.5, onWater: false), "not on water")
        scoop.doorOpen = false
        #expect(!scoop.isScooping(speed: 35, heightAboveWater: 0.5, onWater: true), "door closed")
    }

    @Test func intakeFlowMatchesTheMassFlowFormula() {
        var scoop = WaterScoop()
        scoop.doorOpen = true
        let r = scoop.step(dt: 1, speed: 35, heightAboveWater: 0.5, onWater: true)
        // 1000 kg/m^3 * 0.025 m^2 * 35 m/s * 0.7 = 612.5 kg/s
        #expect(r.scooping)
        #expect(abs(r.massGain - 612.5) < 1e-9)
        #expect(abs(scoop.load - 612.5) < 1e-9)
    }

    @Test func tankStopsAtCapacity() {
        var scoop = WaterScoop()
        scoop.doorOpen = true
        for _ in 0..<100 { _ = scoop.step(dt: 1, speed: 35, heightAboveWater: 0.5, onWater: true) }
        #expect(abs(scoop.load - scoop.capacity) < 1e-9)
        let full = scoop.step(dt: 1, speed: 35, heightAboveWater: 0.5, onWater: true)
        #expect(!full.scooping)
        #expect(full.massGain == 0)
    }

    @Test func scoopDragOnlyWhileScooping() {
        let scoop = WaterScoop()
        #expect(scoop.scoopDrag(airDensity: 1.225, speed: 35, scooping: true) > 0)
        #expect(scoop.scoopDrag(airDensity: 1.225, speed: 35, scooping: false) == 0)
    }

    @Test func releaseDumpsTheTank() {
        var scoop = WaterScoop()
        scoop.doorOpen = true
        _ = scoop.step(dt: 2, speed: 35, heightAboveWater: 0.5, onWater: true)
        let dumped = scoop.release()
        #expect(dumped > 0)
        #expect(scoop.load == 0)
    }

    @Test func nonFiniteStepsTakeNothing() {
        var scoop = WaterScoop()
        scoop.doorOpen = true
        let r = scoop.step(dt: .nan, speed: 35, heightAboveWater: 0.5, onWater: true)
        #expect(!r.scooping)
        #expect(scoop.load == 0)
    }
}
