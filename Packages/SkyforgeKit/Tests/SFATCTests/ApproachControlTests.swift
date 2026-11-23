import Testing
import Foundation
import SFFlightModel
@testable import SFATC
@testable import SFTraffic

private let approachWind = ATCWind(fromDegrees: 270, knots: 8)

/// A tower-view snapshot for approach control. The rest are fixed, typical values.
private func approachView(_ id: String, callsign: String = "SKY417", kind: TrafficKind = .arrival,
                          phase: TrafficPhase, facility: TrafficFacility = .approach, along: Double = 6_000,
                          holding: Bool = false, vectored: Bool = false, distance: Double = 6_000) -> TrafficSnapshot {
    var s = TrafficSnapshot(id: id, callsign: callsign, typeName: "SF-1 Trainer", kind: kind, phase: phase,
                            positionNED: SIMD3<Double>(0, 0, 0), heading: 0, speed: 30,
                            heightAboveRunway: 200, alongRunway: along, distanceToTouchdown: 2_000,
                            isHeavy: false, clearedToLand: false, clearedToTakeoff: false, facility: facility)
    s.holding = holding
    s.vectored = vectored
    s.distanceToApproachFix = distance
    return s
}

@Suite struct ATCApproachTests {

    @Test func aFarArrivalIsVectoredTowardTheFix() {
        var atc = ATCController(runwayDesignator: "28")
        let out = atc.update(time: 0, traffic: [approachView("T1", phase: .inbound, along: 6_000)], wind: approachWind)
        let vector = out.first { $0.control == .vectorToFix }
        #expect(vector?.aircraftID == "T1")
        #expect(vector?.clearance == nil)
    }

    @Test func aVectoredArrivalIsSentDirectWhenClose() {
        var atc = ATCController(runwayDesignator: "28")
        let out = atc.update(time: 0, traffic: [approachView("T1", phase: .inbound, along: 3_000, vectored: true)],
                             wind: approachWind)
        #expect(out.contains { $0.control == .direct && $0.aircraftID == "T1" })
        #expect(!out.contains { $0.control == .vectorToFix })
    }

    @Test func anArrivalAtTheFixIsHeldWhileTheLandingSlotIsTaken() {
        var atc = ATCController(runwayDesignator: "28")
        let traffic = [
            approachView("T1", phase: .inbound, along: 1_200, distance: 800),
            approachView("T2", callsign: "SKY500", phase: .base, facility: .tower, along: -1_000),
        ]
        let out = atc.update(time: 0, traffic: traffic, wind: approachWind)
        #expect(out.contains { $0.control == .hold && $0.aircraftID == "T1" })
        // The arrival on base is the one in the landing slot, not the one on hold.
        #expect(!out.contains { $0.control == .hold && $0.aircraftID == "T2" })
    }

    @Test func aHeldArrivalIsReleasedWhenTheSlotIsFree() {
        var atc = ATCController(runwayDesignator: "28")
        let out = atc.update(time: 0, traffic: [approachView("T1", phase: .inbound, along: 1_200, holding: true,
                                                              distance: 900)], wind: approachWind)
        #expect(out.contains { $0.control == .release && $0.aircraftID == "T1" })
    }

    @Test func ownshipIsNeverHeldOrVectored() {
        var atc = ATCController(runwayDesignator: "28")
        let own = approachView(TrafficOwnship.id, callsign: TrafficOwnship.callsign, phase: .inbound, along: 6_000,
                               distance: 800)
        let base = approachView("T2", callsign: "SKY500", phase: .base, facility: .tower, along: -1_000)
        let out = atc.update(time: 0, traffic: [own, base], wind: approachWind)
        #expect(out.allSatisfy { $0.control == nil || $0.aircraftID != TrafficOwnship.id })
    }
}
