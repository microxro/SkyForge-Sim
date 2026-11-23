// SKYFORGE — Apache-2.0
// Airline career: rank gates, deterministic schedules, on-time and comfort scoring, checklists, save compatibility.
import Testing
import Foundation
@testable import SFCareer

private let alHub = AirportRef(icao: "KMRY", name: "Monterey", latitudeDeg: 36.587, longitudeDeg: -121.843, longestRunwayM: 2_100)
private let alSFO = AirportRef(icao: "KSFO", name: "San Francisco", latitudeDeg: 37.619, longitudeDeg: -122.375, longestRunwayM: 3_600)
private let alSJC = AirportRef(icao: "KSJC", name: "San Jose", latitudeDeg: 37.363, longitudeDeg: -121.929, longestRunwayM: 3_000)
private let alSBP = AirportRef(icao: "KSBP", name: "San Luis Obispo", latitudeDeg: 35.237, longitudeDeg: -120.642, longestRunwayM: 1_900)
private let alLAX = AirportRef(icao: "KLAX", name: "Los Angeles", latitudeDeg: 33.942, longitudeDeg: -118.408, longestRunwayM: 3_700)

private func alRoute(distanceKm: Double = 115, passengers: Int = 2, minimumRank: AirlineRank = .cadet) -> AirlineRoute {
    AirlineRoute(id: "KMRY-1-0", origin: alHub, destination: alSFO, distanceKm: distanceKm, departureMinute: 540,
                 passengers: passengers, minimumRank: minimumRank, expiresDay: 2)
}

/// A clean, on-time, comfortable leg from KMRY to KSFO that lasts 40 minutes.
private func alGoodLeg(durationMin: Double = 40) -> FlightReport {
    FlightReport(kind: .job(jobID: "KMRY-1-0"), aircraftID: "org.skyforge.sfc", departureICAO: "KMRY", arrivalICAO: "KSFO",
                 durationS: durationMin * 60, distanceM: 115_000, landed: true, touchdownSinkFPM: 90, touchdownOffsetM: 0,
                 maxG: 1.1, minG: 0.9, maxBankDeg: 15, fuelUsedKg: 10)
}

private func alFullSOP() -> SOPRun {
    var run = SOPRun()
    for step in SOPChecklist.standard { run.tick(step.id) }
    return run
}

@Suite("Airline ranks")
struct AirlineRankTests {
    @Test func ranksAreOrderedAndChained() {
        #expect(AirlineRank.cadet.next == .firstOfficer)
        #expect(AirlineRank.seniorCaptain.next == nil)
        for rank in AirlineRank.allCases.dropFirst() {
            let below = AirlineRank(rawValue: rank.rawValue - 1)!
            #expect(rank.legsRequired > below.legsRequired)
            #expect(rank.reputationRequired >= below.reputationRequired)
        }
    }

    @Test func earnedRankNeedsLegsAndReputation() {
        #expect(AirlineCareer.earnedRank(legs: 5, reputation: 40) == .firstOfficer)
        #expect(AirlineCareer.earnedRank(legs: 5, reputation: 39) == .cadet)
        #expect(AirlineCareer.earnedRank(legs: 4, reputation: 90) == .cadet)
    }

    @Test func militaryAndLargeAircraftAreNotScheduled() {
        let sfc = Economy.spec("org.skyforge.sfc")!     // 3 seats, civil
        let sf3 = Economy.spec("org.skyforge.sf3")!     // 6 seats, civil
        let sft1 = Economy.spec("org.skyforge.sft1")!   // military
        #expect(AirlineRank.cadet.allows(sfc))
        #expect(!AirlineRank.cadet.allows(sf3))
        #expect(AirlineRank.regionalCaptain.allows(sf3))
        #expect(!AirlineRank.seniorCaptain.allows(sft1))
    }

    @Test func sanitizeStopsRankAheadOfRecord() {
        var a = AirlineCareer()
        a.rank = .seniorCaptain
        a.sanitize()
        #expect(a.rank == .cadet)
    }
}

@Suite("Airline schedule")
struct AirlineScheduleTests {
    @Test func scheduleIsDeterministic() {
        let airports = [alHub, alSFO, alSJC, alSBP, alLAX]
        let a = AirlineSchedule.generate(hub: alHub, airports: airports, dayIndex: 20_000, rank: .cadet)
        let b = AirlineSchedule.generate(hub: alHub, airports: airports, dayIndex: 20_000, rank: .cadet)
        #expect(a == b)
        #expect(!a.isEmpty)
    }

    @Test func sectorsAndSeatsFollowRank() {
        let airports = [alHub, alSFO, alSJC, alSBP, alLAX]
        for rank in AirlineRank.allCases {
            for route in AirlineSchedule.generate(hub: alHub, airports: airports, dayIndex: 7, rank: rank) {
                #expect(route.distanceKm <= rank.maxSectorKm)
                #expect(route.passengers >= 1 && route.passengers <= rank.maxSeats - 1)
                #expect(route.departureMinute % 15 == 0)
                #expect(route.destination.icao != alHub.icao)
            }
        }
    }

    @Test func blockTimeAddsTaxiAllowance() {
        let t = AirlineSchedule.blockMinutes(distanceKm: 222.24)
        #expect(abs(t - (60 + AirlineSchedule.taxiAllowanceMinutes)) < 0.01)
        #expect(AirlineSchedule.blockMinutes(distanceKm: .nan) == AirlineSchedule.taxiAllowanceMinutes)
    }

    @Test func routeBecomesAJobWithAnOnTimeWindow() {
        let route = alRoute()
        let job = route.asJob()
        #expect(job.kind == .passenger)
        #expect(job.passengers == route.passengers)
        #expect(abs(job.deadlineMinutes - (route.expectedBlockMinutes + AirlineRoute.onTimeToleranceMinutes)) < 0.001)
    }

    @Test func acceptanceChecksRankAircraftAndSeats() {
        let sfc = Economy.spec("org.skyforge.sfc")!
        let sf3 = Economy.spec("org.skyforge.sf3")!
        let career = AirlineCareer()
        #expect(AirlineSchedule.canAccept(alRoute(passengers: 2), aircraft: sfc, career: career) == nil)
        #expect(AirlineSchedule.canAccept(alRoute(passengers: 2), aircraft: sf3, career: career) == .aircraftNotAllowed)
        #expect(AirlineSchedule.canAccept(alRoute(passengers: 3), aircraft: sfc, career: career) == .notEnoughSeats)
        #expect(AirlineSchedule.canAccept(alRoute(minimumRank: .regionalCaptain), aircraft: sfc, career: career)
                == .rankTooLow(needed: .regionalCaptain))
    }
}

@Suite("Airline scoring")
struct AirlineScoringTests {
    @Test func onTimeLegScoresHigherThanLateLeg() {
        let route = alRoute()
        let onTime = AirlineEngine.score(report: alGoodLeg(durationMin: 40), route: route, sop: alFullSOP())
        let late = AirlineEngine.score(report: alGoodLeg(durationMin: 90), route: route, sop: alFullSOP())
        #expect(onTime.onTime && !late.onTime)
        #expect(onTime.total > late.total)
        #expect(abs(onTime.total - 100) < 0.001)
    }

    @Test func roughFlyingCostsPassengerComfort() {
        var rough = alGoodLeg()
        rough.maxG = 2.2
        rough.maxBankDeg = 45
        let s = AirlineEngine.score(report: rough, route: alRoute(), sop: alFullSOP())
        #expect(abs(s.comfort - 0.5) < 0.001)
        #expect(s.total < 100)
    }

    @Test func wrongDestinationScoresZero() {
        var r = alGoodLeg()
        r.arrivalICAO = "KLAX"
        let s = AirlineEngine.score(report: r, route: alRoute(), sop: alFullSOP())
        #expect(!s.completed)
        #expect(s.total == 0)
    }

    @Test func settlingAFailedLegCostsReputation() {
        var career = AirlineCareer()
        var r = alGoodLeg()
        r.arrivalICAO = "KLAX"
        let result = AirlineEngine.settle(report: r, route: alRoute(), career: &career)
        #expect(result.reputationDelta == -5)
        #expect(career.reputation == 45)
        #expect(career.legsFlown == 0)
    }

    @Test func goodLegRaisesReputationAndPromotesWhenEligible() {
        var career = AirlineCareer()
        career.legsFlown = 4
        career.legsOnTime = 4
        let result = AirlineEngine.settle(report: alGoodLeg(), route: alRoute(), sop: alFullSOP(), career: &career)
        #expect(result.reputationDelta > 0)
        #expect(career.legsFlown == 5)
        #expect(result.promotedTo == .firstOfficer)
        #expect(career.rank == .firstOfficer)
    }

    @Test func noPromotionWithoutReputation() {
        var career = AirlineCareer()
        career.legsFlown = 4
        career.reputation = 30
        let result = AirlineEngine.settle(report: alGoodLeg(), route: alRoute(), sop: alFullSOP(), career: &career)
        #expect(result.promotedTo == nil)
        #expect(career.rank == .cadet)
    }
}

@Suite("SOP checklist")
struct SOPTests {
    @Test func emptyRunScoresZeroAndFullRunScoresOne() {
        #expect(SOPRun().score() == 0)
        #expect(alFullSOP().score() == 1)
    }

    @Test func unknownStepIdsAreIgnored() {
        var run = SOPRun()
        run.tick("not.a.step")
        #expect(run.completed.isEmpty)
    }

    @Test func missingRequiredStepsAreReported() {
        var run = alFullSOP()
        run.completed.remove("app.stable")
        #expect(run.missedRequired().map(\.id) == ["app.stable"])
        #expect(run.score() < 1)
    }

    @Test func skippingOptionalStepsKeepsMostOfTheScore() {
        var run = alFullSOP()
        for step in SOPChecklist.standard where !step.required { run.completed.remove(step.id) }
        #expect(abs(run.score() - 0.8) < 0.001)
    }
}

@Suite("Airline save compatibility")
struct AirlineSaveTests {
    @Test func oldSaveDecodesWithAFreshRecord() throws {
        let json = Data("{\"pilotName\":\"Old\"}".utf8)
        let state = try JSONDecoder().decode(CareerState.self, from: json)
        #expect(state.airline == AirlineCareer())
    }

    @Test func airlineRecordRoundTrips() throws {
        var state = CareerState()
        state.airline.rank = .firstOfficer
        state.airline.legsFlown = 6
        state.airline.legsOnTime = 4
        state.airline.reputation = 55
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(CareerState.self, from: data)
        #expect(back.airline == state.airline)
    }

    @Test func tamperedAirlineRecordSanitises() {
        var state = CareerState()
        state.airline.reputation = .infinity
        state.airline.legsOnTime = 99
        state.airline.legsFlown = 3
        state.sanitize()
        #expect(state.airline.reputation == 50)
        #expect(state.airline.legsOnTime == 3)
    }
}
