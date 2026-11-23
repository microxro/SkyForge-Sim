import Testing
import Foundation
@testable import SFATC
@testable import SFTraffic

private let approachWind = ATCWind(fromDegrees: 270, knots: 8)

/// Ownship's tower-view snapshot on approach. `bearing` is the NED bearing to the fix, `heading` the flight heading.
private func ownView(along: Double = 6_000, heading: Double = 0, distance: Double = 6_000,
                     bearing: Double = 0) -> TrafficSnapshot {
    var s = TrafficSnapshot(id: TrafficOwnship.id, callsign: TrafficOwnship.callsign, typeName: "SF-1 Trainer",
                            kind: .arrival, phase: .inbound, positionNED: SIMD3<Double>(0, 0, 0), heading: heading,
                            speed: 30, heightAboveRunway: 200, alongRunway: along, distanceToTouchdown: 2_000,
                            isHeavy: false, clearedToLand: false, clearedToTakeoff: false, facility: .approach)
    s.distanceToApproachFix = distance
    s.bearingToApproachFix = bearing
    return s
}

/// A base-leg arrival in the landing slot, so a hold for ownship is needed.
private func landingArrival() -> TrafficSnapshot {
    TrafficSnapshot(id: "T2", callsign: "SKY500", typeName: "SF-1 Trainer", kind: .arrival, phase: .base,
                    positionNED: SIMD3<Double>(0, 0, 0), heading: 0, speed: 30, heightAboveRunway: 150,
                    alongRunway: -1_000, distanceToTouchdown: 1_000, isHeavy: false, clearedToLand: false,
                    clearedToTakeoff: false, facility: .tower)
}

/// The readback choice that is correct for the ownship instruction in `out`.
private func correctChoice(_ out: [ATCInstruction]) throws -> Int {
    let instruction = try #require(out.first { $0.aircraftID == TrafficOwnship.id && $0.readback != nil })
    return try #require(instruction.readback).correctIndex
}

@Suite struct OwnshipApproachTests {

    @Test func aFarOwnshipIsVectoredByReadback() throws {
        var atc = ATCController(runwayDesignator: "28")
        let out = atc.update(time: 0, traffic: [ownView(bearing: 0.5)], wind: approachWind)
        let prompt = try #require(atc.ownshipPrompt)
        #expect(prompt.action == .vector(heading: 0.5))
        #expect(prompt.clearance == nil)
        #expect(prompt.text.contains("turn heading"))
        #expect(out.contains { $0.aircraftID == TrafficOwnship.id && $0.readback != nil })
    }

    @Test func aWrongVectorReadbackIsCounted() throws {
        var atc = ATCController(runwayDesignator: "28")
        let out = atc.update(time: 0, traffic: [ownView()], wind: approachWind)
        let correct = try correctChoice(out)
        let wrong = (correct + 1) % 3
        #expect(atc.readback(choice: wrong, time: 0.5) == false)
        #expect(atc.ownshipPrompt != nil)
        #expect(atc.ownshipStatus.readbackErrors == 1)
        #expect(atc.ownshipStatus.complianceErrors == 1)
    }

    @Test func aVectorFlownOnHeadingCountsAsFlown() throws {
        var atc = ATCController(runwayDesignator: "28")
        let out = atc.update(time: 0, traffic: [ownView(bearing: 0)], wind: approachWind)
        #expect(atc.readback(choice: try correctChoice(out), time: 0.5) == true)
        // Holding the heading for five seconds of decision ticks (0.5 s each) counts the vector as flown.
        for tick in 1...12 {
            _ = atc.update(time: 0.5 + Double(tick) * 0.5, traffic: [ownView(along: 5_000, heading: 0, bearing: 0)],
                           wind: approachWind)
        }
        #expect(atc.ownshipStatus.vectorsFlown == 1)
        #expect(atc.ownshipStatus.vectorsIgnored == 0)
    }

    @Test func aVectorCutShortByDirectIsIgnored() throws {
        var atc = ATCController(runwayDesignator: "28")
        let out = atc.update(time: 0, traffic: [ownView(bearing: 0)], wind: approachWind)
        #expect(atc.readback(choice: try correctChoice(out), time: 0.5) == true)
        // Ownship is close and still well off the vector heading, so the tower sends it direct and counts the miss.
        let direct = atc.update(time: 1.0, traffic: [ownView(along: 3_500, heading: 1.5, bearing: 0)], wind: approachWind)
        #expect(direct.contains { $0.aircraftID == TrafficOwnship.id && $0.text.contains("proceed direct") })
        #expect(direct.allSatisfy { $0.control == nil })
        #expect(atc.ownshipStatus.vectorsIgnored == 1)
        #expect(atc.ownshipStatus.vectorsFlown == 0)
    }

    @Test func aHoldIsGivenWhenTheSlotIsTakenAndOwnshipIsAtTheFix() throws {
        var atc = ATCController(runwayDesignator: "28")
        let out = atc.update(time: 0, traffic: [ownView(along: 1_200, distance: 900), landingArrival()],
                             wind: approachWind)
        let prompt = try #require(atc.ownshipPrompt)
        #expect(prompt.action == .hold)
        #expect(out.contains { $0.aircraftID == TrafficOwnship.id && $0.text.contains("hold at the approach fix") })
    }

    @Test func aFlownHoldIsCountedWhenReleased() throws {
        var atc = ATCController(runwayDesignator: "28")
        let out = atc.update(time: 0, traffic: [ownView(along: 1_200, distance: 900), landingArrival()],
                             wind: approachWind)
        #expect(atc.readback(choice: try correctChoice(out), time: 0.5) == true)
        // The landing spacing keeps the slot taken for 75 s after the last landing call, so release at 100 s.
        let released = atc.update(time: 100, traffic: [ownView(along: 1_200, distance: 900)], wind: approachWind)
        #expect(released.contains { $0.aircraftID == TrafficOwnship.id && $0.text.contains("leave the hold") })
        #expect(atc.ownshipStatus.holdsFlown == 1)
        #expect(atc.ownshipStatus.holdsIgnored == 0)
    }

    @Test func aHoldOwnshipNeverReachesTimesOut() throws {
        var atc = ATCController(runwayDesignator: "28")
        let out = atc.update(time: 0, traffic: [ownView(along: 1_200, distance: 900), landingArrival()],
                             wind: approachWind)
        #expect(atc.readback(choice: try correctChoice(out), time: 0.5) == true)
        // Ownship is still 5 km from the fix after the hold time has run out, with the slot still taken.
        _ = atc.update(time: 130, traffic: [ownView(along: 1_200, distance: 5_000), landingArrival()],
                       wind: approachWind)
        #expect(atc.ownshipStatus.holdsIgnored == 1)
        #expect(atc.ownshipStatus.holdsFlown == 0)
    }
}
