import Testing
import Foundation
import SFFlightModel
@testable import SFATC
@testable import SFTraffic

/// A tower-view snapshot with the fields the controller reads set as given. The rest are fixed, typical values.
private func towerView(_ id: String, callsign: String = "SKY417", kind: TrafficKind = .arrival,
                       phase: TrafficPhase, heavy: Bool = false, clearedToLand: Bool = false,
                       clearedToTakeoff: Bool = false) -> TrafficSnapshot {
    TrafficSnapshot(id: id, callsign: callsign, typeName: "SF-1 Trainer", kind: kind, phase: phase,
                    positionNED: SIMD3<Double>(0, 0, 0), heading: 0, speed: 30,
                    heightAboveRunway: 200, alongRunway: 500, distanceToTouchdown: 2_000,
                    isHeavy: heavy, clearedToLand: clearedToLand, clearedToTakeoff: clearedToTakeoff)
}

@Suite struct ATCControllerTests {

    // MARK: - Phrases

    @Test func numbersAndCallsignsAreSpokenDigitByDigit() {
        #expect(ATCPhrase.digits("280") == "two eight zero")
        #expect(ATCPhrase.digits("") == "")
        #expect(ATCPhrase.callsign("SKY417") == "SKY four one seven")
        #expect(ATCPhrase.runway("28") == "runway two eight")
    }

    @Test func windIsSpokenAndCalmBelowThreeKnots() {
        #expect(ATCPhrase.wind(ATCWind(fromDegrees: 270, knots: 8)) == "wind two seven zero at eight")
        #expect(ATCPhrase.wind(ATCWind(fromDegrees: 180, knots: 2)) == "wind calm")
    }

    // MARK: - Wind

    @Test func windInitialiserRoundsDirectionAndClampsSpeed() {
        // Derived from the initialiser: wrapped = 365 % 360 = 5, then ((5 + 5) / 10) * 10 = 10, then 10 % 360 = 10.
        // So a 5 degree direction rounds up to 10, not down to 0. A negative speed clamps to 0.
        let wind = ATCWind(fromDegrees: 365, knots: -4)
        #expect(wind.fromDegrees == 10)
        #expect(wind.knots == 0)
    }

    @Test func windFromNEDVector() {
        // Derived from ATCWind(windNED:): from = atan2(-y, -x) = atan2(-0, 5) = 0 degrees. Negative x is air moving
        // south, so it comes from the north. The 5 m/s speed is 9.72 kt, which rounds to 10 kt.
        let wind = ATCWind(windNED: SIMD3<Double>(-5, 0, 0))
        #expect(wind.fromDegrees == 0)
        #expect(wind.knots == 10)
    }

    // MARK: - Landing clearances

    @Test func baseArrivalIsClearedToLandOnceAndSpacedByLandingInterval() throws {
        var atc = ATCController(runwayDesignator: "28")
        let wind = ATCWind(fromDegrees: 270, knots: 8)
        let base = towerView("T1", phase: .base)

        // The first sight of the base phase also draws the "report final" advisory, so two instructions come back.
        let first = atc.update(time: 100, traffic: [base], wind: wind)
        #expect(first.count == 2)
        let clearances = first.filter { $0.clearance == .land }
        #expect(clearances.count == 1)
        let text = try #require(clearances.first?.text)
        #expect(text.contains("cleared to land"))

        // The snapshot now shows the clearance already given, so the same tick says nothing new.
        let again = atc.update(time: 100, traffic: [towerView("T1", phase: .base, clearedToLand: true)], wind: wind)
        #expect(again.isEmpty)

        // Ten seconds later the aircraft is still not marked cleared, but landing spacing (75 s) blocks a second one.
        let soon = atc.update(time: 110, traffic: [base], wind: wind)
        #expect(soon.isEmpty)
    }

    @Test func lightArrivalWaitsForWakeSpacingAfterAHeavyLanding() throws {
        var atc = ATCController(runwayDesignator: "28")
        let wind = ATCWind(fromDegrees: 270, knots: 8)

        let heavy = atc.update(time: 100, traffic: [towerView("H1", callsign: "SKY100", phase: .base, heavy: true)],
                               wind: wind)
        #expect(heavy.contains(where: { $0.clearance == .land }))

        // 80 s after the heavy clearance, under the 120 s wake spacing: no clearance yet.
        let tooSoon = atc.update(time: 180, traffic: [towerView("L1", callsign: "SKY200", phase: .base)], wind: wind)
        #expect(tooSoon.allSatisfy({ $0.clearance == nil }))

        // 130 s after it: cleared, with the wake caution in the words.
        let later = atc.update(time: 230, traffic: [towerView("L1", callsign: "SKY200", phase: .base)], wind: wind)
        let clearance = try #require(later.first(where: { $0.clearance == .land }))
        #expect(clearance.text.contains("wake turbulence"))
    }

    // MARK: - Takeoff clearances

    @Test func departureIsClearedOnlyWhenNoArrivalIsOnTheRunway() throws {
        let wind = ATCWind(fromDegrees: 270, knots: 8)
        let departure = towerView("D1", callsign: "SKY300", kind: .departure, phase: .holdShort)

        var atc = ATCController(runwayDesignator: "28")
        let cleared = atc.update(time: 0, traffic: [departure], wind: wind)
        let takeoff = try #require(cleared.first(where: { $0.clearance == .takeoff }))
        #expect(takeoff.aircraftID == "D1")
        #expect(takeoff.text.contains("cleared for takeoff"))

        // An arrival on final holds the departure.
        var onFinal = ATCController(runwayDesignator: "28")
        let heldByFinal = onFinal.update(time: 0, traffic: [departure, towerView("A1", phase: .final)], wind: wind)
        #expect(heldByFinal.allSatisfy({ $0.clearance != .takeoff }))

        // An arrival already cleared to land from base holds it too.
        var onBase = ATCController(runwayDesignator: "28")
        let heldByBase = onBase.update(time: 0, traffic: [departure, towerView("A2", phase: .base, clearedToLand: true)],
                                       wind: wind)
        #expect(heldByBase.allSatisfy({ $0.clearance != .takeoff }))
    }

    // MARK: - Advisories

    @Test func inboundArrivalIsToldToReportDownwindOnce() throws {
        var atc = ATCController(runwayDesignator: "28")
        let wind = ATCWind(fromDegrees: 270, knots: 8)
        let inbound = towerView("T1", phase: .inbound)

        let first = atc.update(time: 0, traffic: [inbound], wind: wind)
        #expect(first.count == 1)
        let advisory = try #require(first.first)
        #expect(advisory.clearance == nil)
        #expect(advisory.text.contains("report downwind"))

        // Same phase on the next tick: nothing new is said.
        let second = atc.update(time: 5, traffic: [inbound], wind: wind)
        #expect(second.isEmpty)
    }

    // MARK: - Log

    @Test func logIsCappedAndRecentLinesKeepOrder() {
        var atc = ATCController(runwayDesignator: "28")
        let wind = ATCWind(fromDegrees: 270, knots: 8)
        // Fifty new inbound arrivals in one tick give fifty advisories. The log keeps only the newest logLimit.
        var traffic: [TrafficSnapshot] = []
        for i in 0..<50 {
            traffic.append(towerView("T\(i)", callsign: "SKY\(100 + i)", phase: .inbound))
        }
        _ = atc.update(time: 0, traffic: traffic, wind: wind)
        #expect(ATCController.logLimit == 40)
        #expect(atc.log.count == ATCController.logLimit)
        #expect(atc.recentLines(2) == [
            "SKY one four eight, runway two eight in use, report downwind.",
            "SKY one four nine, runway two eight in use, report downwind.",
        ])
        #expect(atc.recentLines(0).isEmpty)
    }
}
