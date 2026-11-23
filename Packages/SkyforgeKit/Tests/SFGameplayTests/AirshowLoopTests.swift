// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFGameplay

/// Feeds the loop objective a velocity vector that turns through the vertical plane at 60 m/s.
private func loopSamples(turns: Double, height: Double = 500, speed: Double = 60, steps: Int = 720) -> [FlightSample] {
    (0...steps).map { i in
        let theta = turns * 2 * Double.pi * Double(i) / Double(steps)
        let along = speed * cos(theta)
        let up = speed * sin(theta)
        return FlightSample(time: Double(i) * 0.1,
                            positionNED: SIMD3(0, 0, -height),
                            velocityNED: SIMD3(along, 0, -up),
                            heightAGL: height, onGround: false)
    }
}

@Suite struct AirshowLoopTests {
    @Test func aFullLoopCompletesTheObjective() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.loop(minAGL: 150, minSpeed: 40)),
                                frame: testFrame, aircraftID: "x")
        for s in loopSamples(turns: 1.0) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .succeeded, "a full loop did not complete the mission")
    }

    @Test func aPartialLoopDoesNotComplete() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.loop(minAGL: 150, minSpeed: 40)),
                                frame: testFrame, aircraftID: "x")
        for s in loopSamples(turns: 0.75) { rt.update(sample: s, targets: []) }
        #expect(rt.status == .inProgress, "three quarters of a loop completed the mission")
    }

    @Test func loopFailsBelowTheHeightFloor() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.loop(minAGL: 150, minSpeed: 40)),
                                frame: testFrame, aircraftID: "x")
        for s in loopSamples(turns: 1.0, height: 100) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .failed("Too low for the loop"))
    }
}
