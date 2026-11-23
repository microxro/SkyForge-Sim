import Testing
import Foundation
import SFFlightModel
@testable import SFATC
@testable import SFTraffic

private let handoffWind = ATCWind(fromDegrees: 270, knots: 8)

/// A tower-view snapshot with the controller and phase given. The rest are fixed, typical values.
private func handoffView(_ id: String, callsign: String = "SKY417", kind: TrafficKind = .arrival,
                         phase: TrafficPhase, facility: TrafficFacility) -> TrafficSnapshot {
    TrafficSnapshot(id: id, callsign: callsign, typeName: "SF-1 Trainer", kind: kind, phase: phase,
                    positionNED: SIMD3<Double>(0, 0, 0), heading: 0, speed: 30,
                    heightAboveRunway: 200, alongRunway: 500, distanceToTouchdown: 2_000,
                    isHeavy: false, clearedToLand: false, clearedToTakeoff: false, facility: facility)
}

@Suite struct HandoffTests {

    @Test func anArrivalIsGivenRadarContactThenHandedToTheTower() throws {
        var atc = ATCController(runwayDesignator: "28")
        let first = atc.update(time: 0, traffic: [handoffView("T1", phase: .inbound, facility: .approach)],
                               wind: handoffWind)
        #expect(first.contains { $0.text == "SKY four one seven, approach, radar contact." })
        #expect(first.contains { $0.text.contains("report downwind") })

        let next = atc.update(time: 60, traffic: [handoffView("T1", phase: .downwind, facility: .tower)],
                              wind: handoffWind)
        let handoff = try #require(next.first { $0.text == "SKY four one seven, contact tower." })
        #expect(handoff.aircraftID == "T1")
        #expect(handoff.clearance == nil)
    }

    @Test func aDepartureIsHandedToDepartureControlOnlyOnce() {
        var atc = ATCController(runwayDesignator: "28")
        _ = atc.update(time: 0, traffic: [handoffView("D1", callsign: "SKY300", kind: .departure, phase: .departing,
                                                      facility: .tower)], wind: handoffWind)
        let handed = handoffView("D1", callsign: "SKY300", kind: .departure, phase: .departing, facility: .departure)
        let said = atc.update(time: 90, traffic: [handed], wind: handoffWind)
        #expect(said.map { $0.text } == ["SKY three zero zero, contact departure."])
        #expect(atc.update(time: 95, traffic: [handed], wind: handoffWind).isEmpty)
    }

    @Test func ownshipIsToldWhoToContactAtEachHandoff() {
        var atc = ATCController(runwayDesignator: "28")
        _ = atc.update(time: 0, traffic: [handoffView(TrafficOwnship.id, callsign: TrafficOwnship.callsign,
                                                      kind: .departure, phase: .departing, facility: .tower)],
                       wind: handoffWind)
        let handed = atc.update(time: 40, traffic: [handoffView(TrafficOwnship.id, callsign: TrafficOwnship.callsign,
                                                                kind: .departure, phase: .departing,
                                                                facility: .departure)], wind: handoffWind)
        #expect(handed.contains { $0.text == "N one zero zero, contact departure." })

        let back = atc.update(time: 300, traffic: [handoffView(TrafficOwnship.id, callsign: TrafficOwnship.callsign,
                                                               phase: .downwind, facility: .tower)], wind: handoffWind)
        #expect(back.contains { $0.text == "N one zero zero, contact tower." })
    }

    @Test func aTowerAircraftWithNoChangeSaysNothingAboutItsController() {
        var atc = ATCController(runwayDesignator: "28")
        let first = atc.update(time: 0, traffic: [handoffView("D2", callsign: "SKY500", kind: .departure,
                                                              phase: .holdShort, facility: .tower)], wind: handoffWind)
        #expect(first.allSatisfy { !$0.text.contains("contact") && !$0.text.contains("radar") })
    }
}
