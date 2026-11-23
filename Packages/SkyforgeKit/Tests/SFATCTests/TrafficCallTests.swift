import Testing
import Foundation
import SFFlightModel
@testable import SFATC
@testable import SFTraffic

/// Ownship in the tower's picture, flying north at the given height above the runway.
private func ownshipView(height: Double = 300) -> TrafficSnapshot {
    TrafficSnapshot(id: TrafficOwnship.id, callsign: TrafficOwnship.callsign, typeName: "SF-1 Trainer",
                    kind: .arrival, phase: .downwind, positionNED: SIMD3<Double>(0, 0, 0), heading: 0, speed: 40,
                    heightAboveRunway: height, alongRunway: 0, distanceToTouchdown: 1_000,
                    isHeavy: false, clearedToLand: false, clearedToTakeoff: false)
}

/// An AI aircraft `east` metres east of ownship, at the given height above the runway.
private func aircraftView(_ id: String, east: Double, height: Double = 300) -> TrafficSnapshot {
    TrafficSnapshot(id: id, callsign: "SKY417", typeName: "SF-1 Trainer", kind: .arrival, phase: .downwind,
                    positionNED: SIMD3<Double>(0, east, 0), heading: 0, speed: 40,
                    heightAboveRunway: height, alongRunway: 0, distanceToTouchdown: 1_000,
                    isHeavy: false, clearedToLand: false, clearedToTakeoff: false)
}

/// Traffic calls are the tower lines addressed to ownship with the word "traffic".
private func trafficCalls(_ instructions: [ATCInstruction]) -> [String] {
    instructions.map { $0.text }.filter { $0.contains(", traffic,") }
}

@Suite struct TrafficCallTests {

    @Test func clockPositionIsRelativeToOwnshipHeading() {
        #expect(ATCController.clockPosition(bearing: Double.pi / 2, heading: 0) == "three o'clock")
        #expect(ATCController.clockPosition(bearing: 0, heading: 0) == "one two o'clock")
        // Traffic dead ahead of a heading of east is at twelve o'clock.
        #expect(ATCController.clockPosition(bearing: Double.pi / 2, heading: Double.pi / 2) == "one two o'clock")
    }

    @Test func altitudeIsSpokenInHundredsOfFeet() {
        #expect(ATCController.altitudeWords(0) == "same altitude")
        #expect(ATCController.altitudeWords(-100) == "three hundred feet below")
        #expect(ATCController.altitudeWords(100) == "three hundred feet above")
    }

    @Test func aircraftInRangeAndHeightIsCalledOnce() throws {
        var atc = ATCController(runwayDesignator: "28")
        let wind = ATCWind(fromDegrees: 270, knots: 8)
        let first = atc.update(time: 100, traffic: [ownshipView(), aircraftView("T1", east: 1_000)], wind: wind)
        let call = try #require(trafficCalls(first).first)
        #expect(trafficCalls(first).count == 1)
        #expect(call.hasPrefix("N one zero zero, traffic, three o'clock, one mile, same altitude."))

        let again = atc.update(time: 110, traffic: [ownshipView(), aircraftView("T1", east: 1_000)], wind: wind)
        #expect(trafficCalls(again).isEmpty)
    }

    @Test func aircraftBeyondRangeOrHeightIsNotCalled() {
        var atc = ATCController(runwayDesignator: "28")
        let wind = ATCWind(fromDegrees: 270, knots: 8)
        let far = atc.update(time: 100, traffic: [ownshipView(), aircraftView("T1", east: 4_000)], wind: wind)
        #expect(trafficCalls(far).isEmpty)

        // 500 m of height difference is outside the 300 m call band, even when close.
        let high = atc.update(time: 110, traffic: [ownshipView(), aircraftView("T2", east: 1_000, height: 800)], wind: wind)
        #expect(trafficCalls(high).isEmpty)
    }

    @Test func callIsMadeAgainOnANewEncounter() {
        var atc = ATCController(runwayDesignator: "28")
        let wind = ATCWind(fromDegrees: 270, knots: 8)
        #expect(trafficCalls(atc.update(time: 100, traffic: [ownshipView(), aircraftView("T1", east: 1_000)], wind: wind)).count == 1)
        // Beyond the clear range the encounter ends, and nothing is called.
        #expect(trafficCalls(atc.update(time: 110, traffic: [ownshipView(), aircraftView("T1", east: 6_000)], wind: wind)).isEmpty)
        // Coming back into range is a new encounter, so the tower calls it again.
        #expect(trafficCalls(atc.update(time: 120, traffic: [ownshipView(), aircraftView("T1", east: 1_000)], wind: wind)).count == 1)
    }
}
