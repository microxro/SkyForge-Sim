// SKYFORGE — Apache-2.0
import Testing
import Foundation
@testable import SFGameplay

/// Samples flying the 3 degree glidepath with a lateral offset, from 4 km out to the threshold, 0.1 s apart.
private func glideSamples(offset: Double, steps: Int = 401) -> [FlightSample] {
    let slope = tan(3.0 * Double.pi / 180)
    return (0..<steps).map { i in
        let along = -4_000 + Double(i) * 10
        let up = max(0, -along * slope)
        return FlightSample(time: Double(i) * 0.1,
                            positionNED: testFrame.ned(along: along, right: offset, up: up),
                            velocityNED: SIMD3(0, 0, 0), heightAGL: up, onGround: false)
    }
}

@Suite struct IFRApproachTests {
    private var mission: MissionDefinition {
        oneObjectiveMission(.ifrApproach(gateDistance: 4_000, glideslopeDeg: 3, tolerance: 30, graceTime: 3))
    }

    @Test func aGlidepathToTheThresholdCompletes() {
        var rt = MissionRuntime(mission: mission, frame: testFrame, aircraftID: "x")
        for s in glideSamples(offset: 0) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .succeeded, "an on-path approach did not complete")
    }

    @Test func strayingOffTheCentrelineFailsAfterTheGrace() {
        var rt = MissionRuntime(mission: mission, frame: testFrame, aircraftID: "x")
        for s in glideSamples(offset: 60) where !rt.isFinished { rt.update(sample: s, targets: []) }
        #expect(rt.status == .failed("Off the glidepath"))
    }
}
