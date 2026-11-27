// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFGameplay

/// Level flight along the runway at 60 m/s, passing through `along` at `right` offset, 300 m up.
private func passSamples(alongFrom x0: Double, to x1: Double, right: Double = 0) -> [FlightSample] {
    stride(from: x0, through: x1, by: x1 >= x0 ? 10 : -10).enumerated().map { i, x in
        FlightSample(time: Double(i) * 0.1,
                     positionNED: testFrame.ned(along: x, right: right, up: 300),
                     velocityNED: SIMD3(60, 0, 0), heightAGL: 300, onGround: false)
    }
}

/// Rolls at `rate` rad/s with no pitch, at 500 m and 60 m/s, for `seconds` at 60 Hz.
private func rollSamples(rate: Double, seconds: Double, pitch: Double = 0) -> [FlightSample] {
    (0...Int(seconds * 60)).map { i in
        FlightSample(time: Double(i) / 60,
                     positionNED: testFrame.ned(along: 0, right: 0, up: 500),
                     velocityNED: SIMD3(60, 0, 0), heightAGL: 500, onGround: false,
                     bodyRates: SIMD3(rate, pitch, 0))
    }
}

@Suite struct GateAndRollTests {
    @Test func flyingThroughTheGateCompletesIt() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.gate(MissionWaypoint(1_000, 0, 300, radius: 50), headingDeg: 0)),
                                frame: testFrame, aircraftID: "x")
        for s in passSamples(alongFrom: 900, to: 1_100) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .succeeded)
    }

    @Test func crossingOutsideTheRingFailsTheGate() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.gate(MissionWaypoint(1_000, 0, 300, radius: 50), headingDeg: 0)),
                                frame: testFrame, aircraftID: "x")
        for s in passSamples(alongFrom: 900, to: 1_100, right: 80) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .failed("Missed the gate"))
    }

    @Test func flyingAwayFromTheGateDoesNotPass() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.gate(MissionWaypoint(1_000, 0, 300, radius: 50), headingDeg: 0)),
                                frame: testFrame, aircraftID: "x")
        for s in passSamples(alongFrom: 1_100, to: 900) { rt.update(sample: s, targets: []) }
        #expect(rt.status == .inProgress)
    }

    @Test func fullFastRollCompletesTheObjective() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.aileronRoll(minAGL: 150, minSpeed: 40)),
                                frame: testFrame, aircraftID: "x")
        for s in rollSamples(rate: 2.5, seconds: 4) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .succeeded)
    }

    @Test func partialRollDoesNotComplete() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.aileronRoll(minAGL: 150, minSpeed: 40)),
                                frame: testFrame, aircraftID: "x")
        for s in rollSamples(rate: 2.5, seconds: 1) { rt.update(sample: s, targets: []) }
        #expect(rt.status == .inProgress)
    }

    @Test func rollWithPitchDriftNeverCompletes() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.aileronRoll(minAGL: 150, minSpeed: 40)),
                                frame: testFrame, aircraftID: "x")
        for s in rollSamples(rate: 2.5, seconds: 4, pitch: 0.5) { rt.update(sample: s, targets: []) }
        #expect(rt.status == .inProgress)
    }

    @Test func rollFailsBelowTheHeightFloor() {
        var rt = MissionRuntime(mission: oneObjectiveMission(.aileronRoll(minAGL: 150, minSpeed: 40)),
                                frame: testFrame, aircraftID: "x")
        let low = rollSamples(rate: 2.5, seconds: 1).map { s -> FlightSample in
            var c = s; c.heightAGL = 100; return c
        }
        for s in low where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .failed("Too low for the roll"))
    }
}
